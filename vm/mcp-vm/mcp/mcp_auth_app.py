"""mcp-auth — the OAuth 2.1 gateway that fronts the graphify MCP server.

Installed to /usr/local/bin/mcp_auth_app.py by build-ops/vm/mcp-vm/mcp.sh; run by
/usr/local/bin/mcp-auth, which is the ExecStart of mcp-auth.service. It listens on 0.0.0.0:8080 and is the only thing the load
balancer can reach; graphify itself moved to 127.0.0.1:8081.

WHY THIS EXISTS. Until this image the server was gated by one shared static bearer key,
set as a raw Authorization header in every developer's ~/.claude.json. That works only in
clients that let you set a raw header — Claude Code can, Claude Desktop and claude.ai
custom connectors cannot, because they speak the MCP authorization spec's OAuth flow and
nothing else. It also could not be revoked for one person: rotating the key revoked
everybody. Both problems are the same problem, and this file is the fix.

WHY GOOGLE IS NOT ENOUGH ON ITS OWN. Per the MCP authorization spec (2025-11-25) a client
obtains OAuth credentials by Client ID Metadata Documents, pre-registration, or Dynamic
Client Registration. Google supports none of the first two for third parties and has no
DCR endpoint at all, and it does not implement RFC 8707 `resource`, so it cannot mint a
token audience-bound to https://mcp.deployza.com/mcp — which the spec REQUIRES the
resource server to validate. Something has to sit between Claude and Google.

That something is FastMCP's OAuthProxy (via GoogleProvider), which exists for exactly
this bridge: it answers /register with our one fixed Google client, runs authorization
code + PKCE against Google using one fixed redirect URI, encrypts the upstream token, and
issues its OWN audience-bound JWT to the client. Clients never receive a Google token, so
there is no token passthrough — the confused-deputy failure the spec calls out.

WHO IS ALLOWED: anyone with a deployza.com Google Workspace account. There is no group
check and no allowlist — see WorkspaceDomainMiddleware below for what that does and does
not buy.

THE SERVICE IS CALLED "Deployza MCP" wherever a person sees it — the name clients list it
under, the denial messages, the JSON at /. Not a bare "MCP", which is the name of the
protocol and of every other server a developer has registered.

  Claude -> LB -> :8080 mcp-auth -> 127.0.0.1:8081 graphify
                  ^ this file      ^ upstream package, untouched, still gated by
                                     its API key, which is now an INTERNAL-ONLY
                                     credential and must never be handed to a
                                     person again.
"""

from __future__ import annotations

import logging
import os
import socket

from fastmcp import FastMCP
from fastmcp.client.transports import StreamableHttpTransport
from fastmcp.exceptions import McpError
from fastmcp.server import create_proxy
from fastmcp.server.auth.providers.google import GoogleProvider
from fastmcp.server.dependencies import get_access_token
from fastmcp.server.middleware import Middleware, MiddlewareContext
from fastmcp.server.providers.proxy import ProxyClient
from key_value.aio.stores.disk import DiskStore
from mcp.types import INVALID_REQUEST, ErrorData
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse

log = logging.getLogger("mcp-auth")


# ---------------------------------------------------------------------------
# Configuration.
#
# Everything comes from the environment, which mcp-auth populates from
# /etc/mcp/mcp.env plus three Secret Manager fetches. Same discipline as mcp-serve:
# secrets reach this process through the environment, never through argv where any
# local user's `ps` would read them.
# ---------------------------------------------------------------------------
def _env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or value == "":
        raise SystemExit(f"mcp-auth: {name} is not set")
    return value


class Config:
    def __init__(self) -> None:
        self.public_url = _env("MCP_PUBLIC_URL").rstrip("/")
        self.resource = _env("MCP_RESOURCE")
        self.bind_port = int(_env("MCP_AUTH_PORT", "8080"))

        # Where graphify itself listens. Loopback: the gateway is the only path in.
        self.upstream_host = _env("MCP_BIND", "127.0.0.1")
        self.upstream_port = int(_env("MCP_PORT", "8081"))
        self.upstream_path = _env("MCP_HTTP_PATH", "/mcp")

        # Fetched by the mcp-auth wrapper, not read from disk here.
        self.google_client_id = _env("MCP_GOOGLE_CLIENT_ID")
        self.google_client_secret = _env("MCP_GOOGLE_CLIENT_SECRET")
        self.jwt_signing_key = _env("MCP_JWT_SIGNING_KEY")
        self.mcp_api_key = _env("MCP_API_KEY")

        self.allowed_domain = _env("MCP_ALLOWED_DOMAIN")
        self.auth_state = _env("MCP_AUTH_STATE")

    @property
    def upstream_url(self) -> str:
        return f"http://{self.upstream_host}:{self.upstream_port}{self.upstream_path}"


def _denied(message: str) -> McpError:
    """An MCP-level refusal.

    McpError takes an ErrorData, not a string — passing a string raises a
    validation error inside the error path, which is the worst possible place for
    a bug because it turns a clean denial into a 500.
    """
    return McpError(ErrorData(code=INVALID_REQUEST, message=message))


class WorkspaceDomainMiddleware(Middleware):
    """Refuses every MCP request from an account outside the Workspace domain.

    DELIBERATELY REDUNDANT, AND KEPT ANYWAY. The Google OAuth client's consent screen
    is set to Internal, so Google itself refuses any account outside deployza.com
    before a request ever reaches this process. That is the real boundary. This check
    is the one that survives a consent screen quietly reconfigured to External — a
    single console setting, in a place nobody looks, with no signal that anything
    changed.

    It is also where the audit trail comes from: every call is logged against the
    identity that made it, which the shared key could never do.

    WHAT THIS DOES NOT DO, and it matters. It reads a fixed claim on a token this
    gateway signed itself, so nothing is re-checked against Google on any request.
    An issued token therefore keeps working until it EXPIRES, even after the Workspace
    account behind it has been suspended. The revocation window is the access-token
    lifetime — not five minutes, and not immediate. Shorten the lifetime if that
    window ever needs to be tighter; there is no per-person revocation short of
    offboarding, and the only mass lever is rotating MCP_JWT_SIGNING_KEY.

    A denied caller gets a JSON-RPC error, not an HTTP 403 with WWW-Authenticate. The
    spec would prefer the latter, but the token IS valid — the account is simply not
    permitted — and re-authorizing would not help, so a hard error is the honest
    answer. Revisit if a client ever handles 403/insufficient_scope better than this.
    """

    def __init__(self, allowed_domain: str) -> None:
        self._suffix = "@" + allowed_domain.strip().lower()

    async def on_request(self, context: MiddlewareContext, call_next):
        token = get_access_token()
        email = ((token.claims.get("email") if token else None) or "").strip().lower()

        if not email:
            log.warning("denied: token carries no email claim")
            raise _denied("not authorized to use Deployza MCP")

        if not email.endswith(self._suffix):
            # Should be unreachable while the consent screen is Internal. If this
            # ever fires, the consent screen is the first thing to check.
            log.warning("denied: %s is outside the Workspace domain", email)
            raise _denied(f"{email} is not authorized to use Deployza MCP")

        return await call_next(context)


# ---------------------------------------------------------------------------
# The server.
# ---------------------------------------------------------------------------
def build_app(cfg: Config):
    """Return the ASGI app: OAuth endpoints + /healthz + the proxied /mcp."""

    # GoogleProvider IS an OAuthProxy: it presents DCR to clients while holding one
    # pre-registered Google client underneath. base_url must be the public origin —
    # it is what the advertised redirect URI, the issuer and the token audience are
    # all derived from, so a wrong value here fails discovery in a confusing way.
    #
    # client_storage takes an AsyncKeyValue store, NOT a path — a path is silently
    # the wrong type and fails at construction. DiskStore needs
    # py-key-value-aio[disk]; the image's install-mcp.sh (build-vm-images) installs
    # it explicitly rather than relying on it arriving as somebody's transitive
    # dependency.
    auth = GoogleProvider(
        client_id=cfg.google_client_id,
        client_secret=cfg.google_client_secret,
        base_url=cfg.public_url,
        redirect_path="/auth/callback",
        required_scopes=["openid", "email"],
        jwt_signing_key=cfg.jwt_signing_key,
        client_storage=DiskStore(directory=cfg.auth_state),
    )

    # THE COMPOSITION, and it is deliberate rather than obvious.
    #
    # create_proxy() takes no auth= — a proxy is a plain FastMCP server. So the
    # authenticated server is built first and the proxy is MOUNTED into it, which is
    # the documented "adding proxied components to an existing server" shape. Auth
    # therefore belongs to the outer server and covers everything, including the
    # tools that arrive from upstream.
    #
    # mount() with NO PREFIX: graphify's ten tools must keep the names every prompt,
    # every doc and every developer's muscle memory already uses. A prefix here would
    # rename query_graph to something_query_graph and quietly break all of it.
    # The name clients see when they list the server. "Deployza MCP" rather than a
    # bare "mcp": developers register several MCP servers, and a generic name is
    # indistinguishable from every other one in the picker.
    mcp = FastMCP(name="Deployza MCP", auth=auth)

    # The upstream hop. graphify runs --stateless, so the proxy can hold one session
    # instead of re-doing the MCP initialize handshake on every call — worth having
    # on a burstable shared core where the hourly refresh already competes for the
    # same CPU.
    #
    # THE API KEY IS INJECTED HERE AND NOWHERE ELSE. It is no longer a user-facing
    # credential; it is the loopback password between these two processes.
    #
    # WATCH THIS ON THE FIRST WARM DEPLOY: mcp-refresh restarts mcp.service whenever
    # the graph changes (~2 s, up to hourly), which drops whatever session the proxy
    # is holding. The client is expected to reconnect on the next call; if instead
    # the gateway starts returning errors after a refresh, this is the first place to
    # look, and the fix is a fresh session per request rather than a reused one.
    upstream = ProxyClient(
        transport=StreamableHttpTransport(
            url=cfg.upstream_url,
            headers={"Authorization": f"Bearer {cfg.mcp_api_key}"},
        )
    )
    mcp.mount(create_proxy(upstream, name="deployza-mcp-upstream"))

    mcp.add_middleware(WorkspaceDomainMiddleware(cfg.allowed_domain))

    # -----------------------------------------------------------------------
    # /healthz — unauthenticated, and the reason the load balancer's health check
    # could finally move from TCP to HTTP (build-terraform dz-builds/load-balancing.tf).
    #
    # The old TCP check proved only that something had port 8080 open. This proves
    # the gateway is running AND that graphify is listening behind it, which is the
    # failure this service actually has: graphify crash-loops on a missing graph.
    #
    # A TCP connect, not an MCP call: it must stay cheap enough to run every 10
    # seconds forever, and must not need a token of its own.
    # -----------------------------------------------------------------------
    @mcp.custom_route("/healthz", methods=["GET"])
    async def healthz(request: Request) -> PlainTextResponse:
        try:
            with socket.create_connection(
                (cfg.upstream_host, cfg.upstream_port), timeout=2
            ):
                pass
        except OSError as exc:
            return PlainTextResponse(f"graphify unreachable: {exc}", status_code=503)
        return PlainTextResponse("ok")

    # A bare / that says what this is. Without it the host answers 404 at the root,
    # which reads as "misconfigured DNS" to anyone who pastes the URL into a browser
    # — and people will, now that there is a login flow to try.
    @mcp.custom_route("/", methods=["GET"])
    async def root(request: Request) -> JSONResponse:
        return JSONResponse(
            {
                "service": "Deployza MCP",
                "mcp_endpoint": cfg.resource,
                "docs": "build-terraform/docs/mcp.md",
            }
        )

    return mcp


def main() -> None:
    # journald captures stdout/stderr, and this image forwards journald to the serial
    # console — which is the only way to read logs on a VM with no SSH (§7). INFO is
    # deliberate: the token-issuance and denial lines are the audit trail.
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    cfg = Config()
    mcp = build_app(cfg)

    # The path MUST be /mcp: it is the canonical resource URI advertised in the
    # protected-resource metadata, the audience the issued tokens are bound to, and
    # what every already-registered client has in its config. Changing it is a
    # breaking change for every developer, not a rename.
    mcp.run(
        transport="http",
        host="0.0.0.0",
        port=cfg.bind_port,
        path="/mcp",
    )


if __name__ == "__main__":
    main()
