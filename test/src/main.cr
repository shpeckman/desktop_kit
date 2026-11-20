# src/main.cr
# The live test harness of desktop_kit: see README.md.
require "./desktop_kit/test/subject"

exit Livetest.run(ARGV, DesktopKit::Test::Subject.new)
