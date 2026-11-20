# spec/pure/ui/command_spec.cr
require "../../spec_helper"

describe DesktopKit::Command do
  it "matches every word of a query, ignoring case" do
    command = DesktopKit::Command.new("Split Right", DesktopKit::Action::NewSplit.new(:right), "pane")
    command.matches?("").should be_true
    command.matches?("split").should be_true
    command.matches?("RIGHT spl").should be_true
    command.matches?("pane").should be_true
    command.matches?("split left").should be_false
  end

  it "has defaults with distinct titles and actions" do
    defaults = DesktopKit::Command.defaults
    defaults.map(&.title).uniq.size.should eq defaults.size
    defaults.map(&.action.detailed_name).uniq.size.should eq defaults.size
  end
end
