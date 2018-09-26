using Sockets
import AssetRegistry, JSON
using WebSockets: is_upgrade, upgrade

struct WSConnection{T} <: WebIO.AbstractConnection
    sock::T
end

Sockets.send(p::WSConnection, data) = writeguarded(p.sock, JSON.json(data))
Base.isopen(p::WSConnection) = isopen(p.sock)

"""
Prints a inlineable representation of `node` to `io`
"""
function tohtml(io, node)
    # Is this a more reliable way to mount the webio nodes?!
    # At least with the default WebIO method I get some flaky behaviour
    id = rand(UInt64) # TODO is this needed to be unique?!
    print(io,
        "<div id=\"$id\"></div>",
        "<script style='display:none'>",
        "WebIO.mount(document.getElementById('$id'),"
    )
    WebIO.jsexpr(io, WebIO.render(node))
    print(io, ")</script>")
end

function asseturl(file)
    path = normpath(file)
    WebIO.baseurl[] * AssetRegistry.register(path)
end

wio_asseturl(file) = asseturl(string(normpath(WebIO.assetpath), '/', normpath(file)))

function serve_assets(req, serve_page)
    response = serve_page(req)
    response !== missing && return response
    if haskey(AssetRegistry.registry, req.target)
        filepath = AssetRegistry.registry[req.target]
        if isfile(filepath)
            return HTTP.Response(
                200,
                ["Content-Type" => "application/octet-stream"],
                body = read(filepath)
            )
        end
    end
    return "not found"
end

function websocket_handler(ws)
    conn = WSConnection(ws)
    while isopen(ws)
        data, success = WebSockets.readguarded(ws)
        !success && break
        msg = JSON.parse(String(data))
        WebIO.dispatch(conn, msg)
    end
end

struct WebIOServer{S}
    server::S
    serve_task::Task
end

kill!(server::WebIOServer) = put!(server.server.in, HTTP.Servers.KILL)

const singleton_instance = Ref{WebIOServer}()

const routing_callback = Ref{Any}((req)-> missing)

"""
    WebIOServer(
        default_response::Function = ()-> "";
        baseurl::String = "127.0.0.1", http_port::Int = "8081",
        ws_port::Int = 8000, verbose = false, singleton = true,
        logging_io = devnull
    )

usage:

```example
    asset_port = 8081
    base_url = "127.0.0.1"
    const app = Ref{Any}()
    #WebIO.setbaseurl!(baseurl) # plus port!?
    server = WebIOServer(
            baseurl = base_url, http_port = asset_port, verbose = true
        ) do req
        req.target != "/" && return missing # don't do anything
        isassigned(app) || return "no app"
        ws_url = string("ws://", base_url, ':', asset_port, "/webio_websocket/")
        webio_script = wio_asseturl("/webio/dist/bundle.js")
        ws_script = wio_asseturl("/providers/websocket_connection.js")
        return sprint() do io
            print(io, "
                <!doctype html>
                <html>
                <head>
                <meta charset="UTF-8">
                <script> var websocket_url = \$(repr(ws_url)) </script>
                <script src="\$webio_script"></script>
                <script src="\$ws_script"></script>
                </head>
                <body>
            ")
            tohtml(io, app[])
            print(io, "
                </body>
                </html>
            ")
        end
    end

    w = Scope()

    obs = Observable(w, "rand-value", 0.0)

    on(obs) do x
        println("JS sent \$x")
    end

    using JSExpr
    app[] = w(
      dom"button"(
        "generate random",
        events=Dict("click"=>@js () -> \$obs[] = Math.random()),
      ),
    );
```
"""
function WebIOServer(
        default_response::Function = (req)-> missing;
        baseurl::String = "127.0.0.1", http_port::Int = 8081,
        verbose = false, singleton = true,
        websocket_route = "/webio_websocket/",
        logging_io = devnull,
        server_kw_args...
    )
    # TODO test if actually still running, otherwise restart even if singleton
    if !singleton || !isassigned(singleton_instance)
        handler = HTTP.HandlerFunction() do req
            serve_assets(req, default_response)
        end
        wshandler = WebSockets.WebsocketHandler() do req, sock
            try
                req.target == websocket_route && websocket_handler(sock)
            catch e
                @warn(e)
            end
        end
        server = WebSockets.ServerWS(handler, wshandler; server_kw_args...)
        server_task = @async (ret = WebSockets.serve(server, baseurl, http_port, verbose))
        singleton_instance[] = WebIOServer(server, server_task)
    end
    return singleton_instance[]
end

const webio_server_config = Ref{typeof((url = "", http_port = 0, ws_url = ""))}()

"""
Fetches the global configuration for our http + websocket server from environment
variables. It will memoise the result, so after a first call, any update to
the environment will get ignored.
"""
function global_server_config()
    if !isassigned(webio_server_config)

        setbaseurl!(get(ENV, "JULIA_WEBIO_BASEURL", ""))

        url = get(ENV, "WEBIO_SERVER_HOST_URL", "127.0.0.1")
        http_port = parse(Int, get(ENV, "WEBIO_HTTP_PORT", "8081"))
        ws_default = string(url, ":", http_port, "/webio_websocket/")
        ws_url = get(ENV, "WEBIO_WEBSOCKT_URL", ws_default)
        webio_server_config[] = (url = url, http_port = http_port, ws_url = ws_url)

    end
    webio_server_config[]
end

"""
Generic show method that will make sure that an asset & websocket server is running
it will print the required html scripts + WebIO div mounting code directly into `io`.
can be used in the following way to create a generic display method for webio:
    ```example
    function Base.display(d::MyWebDisplay, m::MIME"application/webio", app)
        println(d.io, "outer html")
        show(io, m, app)
        println(d.io, "close outer html")
    end
    ```
The above example enables display code & webio code that doesn't rely on any
provider dependencies.
If you want to host the bundle + websocket script somewhere else, you can also call:
    ```example
    function Base.display(d::MyWebDisplay, m::MIME"application/webio", app)
        println(d.io, "outer html")
        show(io, m, app, bundle_url, websocket_url)
        println(d.io, "close outer html")
    end
    ```
"""
function Base.show(io::IO, m::MIME"application/webio", app::Union{Scope, Node})
    webio_script = wio_asseturl("/webio/dist/bundle.js")
    ws_script = wio_asseturl("/providers/websocket_connection.js")
    show(io, m, app, webio_script, ws_script)
    return
end

function Base.show(io::IO, ::MIME"application/webio", app::Union{Scope, Node}, webio_script, ws_script)
    # Make sure we run a server
    c = global_server_config()
    WebIOServer(routing_callback[], baseurl = c.url, http_port = c.http_port)
    println(io, "<script> var websocket_url = $(repr(c.ws_url)) </script>")
    println(io, "<script src=$(repr(webio_script))></script>")
    println(io, "<script src=$(repr(ws_script))   ></script>")
    tohtml(io, app)
    return
end
