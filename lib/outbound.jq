# Build one Xray outbound from an xraybox server object.
# Usage: jq -c --arg iface "$iface" -f outbound.jq <<< "$server_json"
{
  tag: ("srv_" + .id),
  protocol: "vless",
  settings: {
    vnext: [{
      address: .host,
      port: .port,
      users: [(
        {id: .uuid, encryption: "none"}
        + (if (.flow // "") != "" and .transport == "tcp"
           then {flow: .flow} else {} end)
      )]
    }]
  },
  streamSettings: (
    {
      network: (if .transport == "tcp" then "tcp" else .transport end),
      security: (.security // "none")
    }
    + (if (.security // "none") == "reality" then
        {realitySettings: (
          {
            serverName: (.sni // ""),
            fingerprint: (.fingerprint // "chrome"),
            publicKey: (.public_key // ""),
            spiderX: (.spider_x // "/")
          }
          + (if (.short_id // "") != "" then {shortId: .short_id} else {} end)
        )}
       elif (.security // "none") == "tls" then
        {tlsSettings: (
          {}
          + (if (.sni // "") != "" then {serverName: .sni} else {} end)
          + (if (.fingerprint // "") != "" then {fingerprint: .fingerprint} else {} end)
          + (if ((.alpn // []) | length) > 0 then {alpn: .alpn} else {} end)
          + (if (.pinned_peer_cert_sha256 // "") != ""
             then {pinnedPeerCertSha256: .pinned_peer_cert_sha256} else {} end)
          + (if (.verify_peer_cert_by_name // "") != ""
             then {verifyPeerCertByName: .verify_peer_cert_by_name} else {} end)
        )}
       else {} end)
    + (if .transport == "xhttp" then
        {xhttpSettings: (
          {path: (.path // "/"), mode: (.mode // "auto")}
          + (if (.host_header // "") != "" then {host: .host_header} else {} end)
          + (if .extra != null then {extra: .extra} else {} end)
        )}
       elif .transport == "ws" then
        {wsSettings: (
          {path: (.path // "/")}
          + (if (.host_header // "") != ""
             then {headers: {Host: .host_header}} else {} end)
        )}
       elif .transport == "grpc" then
        {grpcSettings: (
          {serviceName: (.service_name // "")}
          + (if (.mode // "") == "multi" then {multiMode: true} else {} end)
        )}
       elif .transport == "httpupgrade" then
        {httpupgradeSettings: (
          {path: (.path // "/")}
          + (if (.host_header // "") != "" then {host: .host_header} else {} end)
        )}
       elif .transport == "tcp" and (.header_type // "none") == "http" then
        {tcpSettings: {
          header: {
            type: "http",
            request: (
              {path: [(.path // "/")]}
              + (if (.host_header // "") != ""
                 then {headers: {Host: [.host_header]}} else {} end)
            )
          }
        }}
       else {} end)
    + (if $iface != "" then {sockopt: {interface: $iface}} else {} end)
  )
}
