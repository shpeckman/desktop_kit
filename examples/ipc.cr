# examples/ipc.cr
#
# Opens a window in a running application, `examples/hello.cr` by default.
#
#   crystal run examples/ipc.cr -- [application id]
require "../src/apprt"

app_id = ARGV.first? || "org.example.Hello"
begin
  Apprt::IPC.send(app_id, Apprt::Action::NewWindow.new)
rescue ex : Apprt::GLibError | ArgumentError
  STDERR.puts "#{app_id}: #{ex.message}"
  exit 1
end
