# src/apprt/test/subject.cr
require "livetest"

module Apprt::Test
  # :nodoc:
  # Starts `apprt-under-test` with the case's app id as its window class,
  # and with `--global` for cases that set `global: true`.
  class Subject < Livetest::Subject
    def name : String
      "apprt-under-test"
    end

    def keys : Array(String)
      ["global"]
    end

    def check(test : Livetest::Case) : Nil
      field = test.field?("global") || return
      raise field.error("global must be true or false") unless field.text.in?("true", "false")
    end

    def arguments(test : Livetest::Case, app_id : String) : Array(String)
      arguments = ["--class", app_id]
      arguments << "--global" if test.field?("global").try(&.text) == "true"
      arguments
    end
  end
end
