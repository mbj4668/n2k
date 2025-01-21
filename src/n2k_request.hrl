-record(req, {
    buf = undefined :: 'undefined' | binary(),
    gw,
    connectf,
    sendf,
    closef,
    sock = undefined :: 'undefined' | inet:socket()
}).
