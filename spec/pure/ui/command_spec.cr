# spec/pure/ui/command_spec.cr
require "../../spec_helper"

describe Apprt::Command do
  it "matches every word of a query, ignoring case" do
    command = Apprt::Command.new("Split Right", Apprt::Action::NewSplit.new(:right), "pane")
    command.matches?("").should be_true
    command.matches?("split").should be_true
    command.matches?("RIGHT spl").should be_true
    command.matches?("pane").should be_true
    command.matches?("split left").should be_false
  end

  it "has defaults with distinct titles and actions" do
    defaults = Apprt::Command.defaults
    defaults.map(&.title).uniq.size.should eq defaults.size
    defaults.map(&.action.detailed_name).uniq.size.should eq defaults.size
  end
end
