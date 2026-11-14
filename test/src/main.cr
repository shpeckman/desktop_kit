# src/main.cr
# The live test harness of apprt: see README.md.
require "./apprt/test/subject"

exit Livetest.run(ARGV, Apprt::Test::Subject.new)
