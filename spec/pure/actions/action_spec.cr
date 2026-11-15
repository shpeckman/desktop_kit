# spec/pure/actions/action_spec.cr
require "../../spec_helper"

module ActionSpecs
  Apprt.action Refresh, "spec-refresh", payload: {force: Bool}, ipc: true

  Apprt.action Paint, "spec-paint", scope: :split, payload: {color: Color, layers: Int32} do
    enum Color
      Red
      DarkBlue
    end
  end
end

private def round_trip(action : T) : T? forall T
  T.from_variant(action.to_variant)
end

describe Apprt::Action do
  it "names actions by scope, name and payload" do
    {
      Apprt::Action::Quit.new                                        => "app.quit",
      Apprt::Action::PresentSurface.new(7)                           => "app.present-surface(uint64 7)",
      Apprt::Action::DesktopNotification.new("Done", "Build passed") => "app.desktop-notification(('Done', 'Build passed'))",
      Apprt::Action::NewTab.new                                      => "win.new-tab",
      Apprt::Action::GotoTab.new(Apprt::Action::GotoTab::LAST)       => "win.goto-tab(-3)",
      Apprt::Action::CloseTab.new(:other)                            => "tab.close-tab::other",
      Apprt::Action::NewSplit.new(:right)                            => "split.new-split::right",
      Apprt::Action::ResizeSplit.new(:up, 10)                        => "split.resize-split(('up', uint32 10))",
      ActionSpecs::Paint.new(:dark_blue, 2)                          => "split.spec-paint(('dark_blue', 2))",
    }.each { |action, name| action.detailed_name.should eq name }
  end

  it "exposes the payload and the scope" do
    action = Apprt::Action::ResizeSplit.new(:left, 5)
    action.direction.should eq Apprt::Direction::Left
    action.amount.should eq 5
    action.name.should eq "resize-split"
    action.scope.should eq Apprt::Action::Scope::Split
    action.scope.prefix.should eq "split"
  end

  it "round-trips actions through their GAction parameter" do
    round_trip(Apprt::Action::Quit.new).should eq Apprt::Action::Quit.new
    round_trip(Apprt::Action::SizeLimit.new(1, 2, 3, 4)).should eq Apprt::Action::SizeLimit.new(1, 2, 3, 4)
    round_trip(Apprt::Action::SetWindowTheme.new(:dark)).should eq Apprt::Action::SetWindowTheme.new(:dark)
    round_trip(Apprt::Action::MouseVisibility.new(false)).should eq Apprt::Action::MouseVisibility.new(false)
    round_trip(ActionSpecs::Paint.new(:dark_blue, 3)).should eq ActionSpecs::Paint.new(:dark_blue, 3)
  end

  it "rejects parameters that do not carry the payload" do
    Apprt::Action::Quit.from_variant(Apprt::Variant.new(1)).should be_nil
    Apprt::Action::OpenUrl.from_variant(nil).should be_nil
    Apprt::Action::OpenUrl.from_variant(Apprt::Variant.new(1)).should be_nil
    Apprt::Action::CloseTab.from_variant(Apprt::Variant.new("left")).should be_nil
    ActionSpecs::Paint.from_variant(Apprt::Variant.new({"green", 1})).should be_nil
  end

  it "registers built-in and declared actions with their parameter types" do
    infos = Apprt::Action.registry.to_h { |info| {"#{info.scope.prefix}.#{info.name}", info.parameter_type} }
    infos["app.quit"].should be_nil
    infos["app.desktop-notification"].should eq "(ss)"
    infos["win.size-limit"].should eq "(uuuu)"
    infos["split.resize-split"].should eq "(su)"
    infos["app.spec-refresh"].should eq "b"
    infos["split.spec-paint"].should eq "(si)"
    infos.size.should eq Apprt::Action.registry.size
  end

  it "decodes parameters through the registry" do
    info = Apprt::Action.registry.find!(&.name.== "spec-paint")
    info.decode.call(Apprt::Variant.new({"red", 1})).should eq ActionSpecs::Paint.new(:red, 1)
    info.decode.call(nil).should be_nil
  end

  it "allows ipc only where declared" do
    ActionSpecs::Refresh.new(true).ipc?.should be_true
    Apprt::Action::NewWindow.new.ipc?.should be_true
    Apprt::Action::Quit.new.ipc?.should be_false
  end
end
