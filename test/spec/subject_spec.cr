# spec/subject_spec.cr
require "spec"
require "../src/apprt/test/subject"

describe Apprt::Test::Subject do
  it "starts the app with the case's app id as its window class" do
    subject = Apprt::Test::Subject.new
    test = Livetest::Case.parse("demo:\n  steps:\n    - close\n", "/cases/cases.yml", subject.keys).first
    subject.arguments(test, "livetest-1-1").should eq ["--class", "livetest-1-1"]
  end

  it "reads the cases" do
    subject = Apprt::Test::Subject.new
    cases = Livetest::Case.read(File.expand_path("../cases.yml", __DIR__), subject.keys)
    cases.each { |test| subject.check(test) }
    cases.should_not be_empty
  end
end
