# spec/pure/core/translate_spec.cr
require "../../spec_helper"

# Every literal desktop_kit passes to `DesktopKit.tr`, with `\`-continued literals
# joined.
private def built_in_texts : Array(String)
  texts = [] of String
  Dir.glob("#{__DIR__}/../../../src/**/*.cr").each do |file|
    source = File.read(file).gsub(/"\s*\\\n\s*"/, "")
    source.scan(/DesktopKit\.tr\("((?:[^"\\]|\\.)*)"\)/) { |match| texts << match[1] }
  end
  texts.uniq.sort!
end

private def with_translator(translator : String -> String, &) : Nil
  previous = DesktopKit.translator
  DesktopKit.translator = translator
  yield
ensure
  DesktopKit.translator = previous.not_nil!
end

describe "DesktopKit.translator" do
  it "passes texts through by default" do
    DesktopKit.translator.call("Quit").should eq "Quit"
  end

  it "translates the built-in commands and menu" do
    with_translator(->(text : String) { "<#{text}>" }) do
      DesktopKit::Command.defaults.first.title.should eq "<New Window>"
      DesktopKit::Menu.window.sections.first.first.label.should eq "<New Window>"
    end
  end

  it "keeps the English text when the translator raises" do
    with_translator(->(text : String) : String { raise "no catalog" }) do
      DesktopKit.tr("Quit").should eq "Quit"
    end
  end

  it "lists every built-in text in the README" do
    readme = File.read("#{__DIR__}/../../../README.md")
    missing = built_in_texts.reject { |text| readme.includes?("| #{text} |") }
    missing.should be_empty
  end
end
