# spec/subject_spec.cr
require "spec"
require "../src/apprt/test/subject"

private def parse(yaml : String) : Livetest::Case
  Livetest::Case.parse(yaml, "/cases/cases.yml", Apprt::Test::Subject.new.keys).first
end

describe Apprt::Test::Subject do
  it "starts the app with the case's app id as its window class" do
    test = parse("demo:\n  steps:\n    - close\n")
    Apprt::Test::Subject.new.arguments(test, "livetest-1-1").should eq ["--class", "livetest-1-1"]
  end

  it "binds the global shortcut for global cases" do
    test = parse("demo:\n  global: true\n  steps:\n    - close\n")
    Apprt::Test::Subject.new.arguments(test, "livetest-1-1").should eq ["--class", "livetest-1-1", "--global"]
  end

  it "rejects other global values" do
    subject = Apprt::Test::Subject.new
    expect_raises(Livetest::Case::Error, /global must be true or false/) do
      subject.check(parse("demo:\n  global: yes please\n  steps:\n    - close\n"))
    end
  end

  it "reads the cases" do
    subject = Apprt::Test::Subject.new
    cases = Livetest::Case.read(File.expand_path("../cases.yml", __DIR__), subject.keys)
    cases.each { |test| subject.check(test) }
    cases.should_not be_empty
  end
end
