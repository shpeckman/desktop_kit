# spec/spec_helper.cr
require "spec"
require "log/spec"
require "socket"
require "../src/desktop_kit"

# Sets the environment variable *name* to *value* (deletes it for `nil`) for
# the duration of the block.
def with_env(name : String, value : String?, &)
  saved = ENV[name]?
  value ? (ENV[name] = value) : ENV.delete(name)
  yield
ensure
  saved ? (ENV[name] = saved) : ENV.delete(name)
end

# Binds a datagram socket and points NOTIFY_SOCKET at it for the block.
def with_notify_socket(& : Socket ->)
  path = File.tempname("desktop-kit-notify", ".sock")
  socket = Socket.unix(Socket::Type::DGRAM)
  socket.bind(Socket::UNIXAddress.new(path))
  with_env("NOTIFY_SOCKET", path) { yield socket }
ensure
  socket.try &.close
  path.try { |file| File.delete?(file) }
end

# Returns the datagrams queued on *socket*.
def notifications(socket : Socket) : Array(String)
  socket.read_timeout = 50.milliseconds
  messages = [] of String
  buffer = Bytes.new(4096)
  loop do
    size = socket.read(buffer)
    messages << String.new(buffer[0, size])
  rescue IO::TimeoutError
    break
  end
  messages
end
