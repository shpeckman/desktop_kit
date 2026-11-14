# src/apprt/test/subject.cr
require "livetest"

module Apprt::Test
  # :nodoc:
  # Starts `apprt-under-test` with the case's app id as its window class.
  class Subject < Livetest::Subject
    def name : String
      "apprt-under-test"
    end

    def arguments(test : Livetest::Case, app_id : String) : Array(String)
      ["--class", app_id]
    end
  end
end
