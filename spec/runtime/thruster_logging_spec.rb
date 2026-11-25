require "rails_helper"
require "net/http"
require "socket"
require "timeout"

RSpec.describe "Production image request logging" do
  # Exercise the bundled proxy locally, with no TLS or outside service. The tiny
  # upstream isolates Thruster stdout from Rails (covered by the request specs).
  def proxy_stdout(log_requests)
    backend = TCPServer.new("127.0.0.1", 0)
    target_port = backend.addr[1]
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.addr[1]
    listener.close
    upstream = Thread.new do
      loop do
        socket = backend.accept
        socket.gets
        while (line = socket.gets) && line != "\r\n"
        end
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        socket.close
      end
    end
    reader, writer = IO.pipe
    output = Thread.new { reader.read }
    pid = Process.spawn(
      { "HTTP_PORT" => port.to_s, "TARGET_PORT" => target_port.to_s,
        "LOG_REQUESTS" => log_requests, "TLS_DOMAIN" => "" },
      RbConfig.ruby, Rails.root.join("bin/thrust").to_s, RbConfig.ruby, "-e", "sleep",
      out: writer, err: writer, pgroup: true
    )
    writer.close
    path = "/v1/releases/sha1/5f026649611c9606ce0bf70dc1552e054e7df5bc.json"
    Timeout.timeout(10) do
      loop do
        begin
          http = Net::HTTP.new("127.0.0.1", port, nil)
          http.open_timeout = 1
          http.read_timeout = 1
          response = http.get(path, { "X-Forwarded-For" => "203.0.113.19" })
          break if response.code == "200"
        rescue Errno::ECONNREFUSED, EOFError
          # The proxy may still be starting.
        end
        sleep 0.05
      end
    end
    Process.kill("TERM", pid)
    Process.wait(pid)
    pid = nil
    output.value
  ensure
    if pid
      Process.kill("TERM", pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    end
    writer&.close unless writer&.closed?
    upstream&.kill&.join
    backend&.close
    output&.join
    reader&.close
  end

  it "disables Thruster access lines with the Dockerfile setting, with an enabled control" do
    setting = Rails.root.join("Dockerfile").read.match(/^\s+LOG_REQUESTS="([^"]+)"/)&.captures&.first
    expect(setting).to eq("false")
    enabled = proxy_stdout("true")
    expect(enabled).to include("/v1/releases/sha1/5f026649611c9606ce0bf70dc1552e054e7df5bc.json")
    expect(enabled).to include('"remote_addr":"203.0.113.19"')
    disabled = proxy_stdout(setting)
    expect(disabled).not_to include("/v1/releases", "5f026649611c9606ce0bf70dc1552e054e7df5bc", "203.0.113.19", "127.0.0.1")
  end
end
