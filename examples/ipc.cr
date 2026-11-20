# examples/ipc.cr
#
# Opens a window in a running application, `examples/hello.cr` by default.
#
#   crystal run examples/ipc.cr -- [application id]
require "../src/desktop_kit"

app_id = ARGV.first? || "org.example.Hello"
begin
  DesktopKit::IPC.send(app_id, DesktopKit::Action::NewWindow.new)
rescue ex : DesktopKit::GLibError | ArgumentError
  STDERR.puts "#{app_id}: #{ex.message}"
  exit 1
end
