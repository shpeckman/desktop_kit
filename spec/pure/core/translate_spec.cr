# spec/pure/core/translate_spec.cr
require "../../spec_helper"

# Every literal apprt passes to `Apprt.tr`, with `\`-continued literals
# joined.
private def built_in_texts : Array(String)
  texts = [] of String
  Dir.glob("#{__DIR__}/../../../src/**/*.cr").each do |file|
    source = File.read(file).gsub(/"\s*\\\n\s*"/, "")
    source.scan(/Apprt\.tr\("((?:[^"\\]|\\.)*)"\)/) { |match| texts << match[1] }
  end
  texts.uniq.sort!
end

private def with_translator(translator : String -> String, &) : Nil
  previous = Apprt.translator
  Apprt.translator = translator
  yield
ensure
  Apprt.translator = previous.not_nil!
end

describe "Apprt.translator" do
  it "passes texts through by default" do
    Apprt.translator.call("Quit").should eq "Quit"
  end

  it "translates the built-in commands and menu" do
    with_translator(->(text : String) { "<#{text}>" }) do
      Apprt::Command.defaults.first.title.should eq "<New Window>"
      Apprt::Menu.window.sections.first.first.label.should eq "<New Window>"
    end
  end

  it "keeps the English text when the translator raises" do
    with_translator(->(text : String) : String { raise "no catalog" }) do
      Apprt.tr("Quit").should eq "Quit"
    end
  end

  it "lists every built-in text in the README" do
    readme = File.read("#{__DIR__}/../../../README.md")
    missing = built_in_texts.reject { |text| readme.includes?("| #{text} |") }
    missing.should be_empty
  end
end
