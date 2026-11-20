# src/desktop_kit/test/subject.cr
require "livetest"

module DesktopKit::Test
  # :nodoc:
  # Starts `desktop-kit-under-test` with the case's app id as its window class,
  # with `--global` for cases that set `global: true` and with `--dutch`
  # for cases that set `dutch: true`.
  class Subject < Livetest::Subject
    # Case keys that pass the option of the same name when true.
    private FLAGS = ["global", "dutch"]

    def name : String
      "desktop-kit-under-test"
    end

    def keys : Array(String)
      FLAGS
    end

    def check(test : Livetest::Case) : Nil
      FLAGS.each do |key|
        field = test.field?(key) || next
        raise field.error("#{key} must be true or false") unless field.text.in?("true", "false")
      end
    end

    def arguments(test : Livetest::Case, app_id : String) : Array(String)
      arguments = ["--class", app_id]
      FLAGS.each { |key| arguments << "--#{key}" if test.field?(key).try(&.text) == "true" }
      arguments
    end
  end
end
