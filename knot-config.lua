-- Knot Resolver mit Prometheus Metriken

modules = {
    'stats',
    'http'
}

net.listen('127.0.0.1', 53)

cache.size = 300 * MB

-- HTTP Interface für Prometheus (Port 8453)
http = {
    listen = '127.0.0.1:8453',
    tls = false
}
