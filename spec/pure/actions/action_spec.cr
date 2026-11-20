# spec/pure/actions/action_spec.cr
require "../../spec_helper"

module ActionSpecs
  DesktopKit.action Refresh, "spec-refresh", payload: {force: Bool}, ipc: true

  DesktopKit.action Paint, "spec-paint", scope: :split, payload: {color: Color, layers: Int32} do
    # Not file-private: the `Variant` macro expansion must see it.
    enum Color
      Red
      DarkBlue
    end
  end
end

private def round_trip(action : T) : T? forall T
  T.from_variant(action.to_variant)
end

describe DesktopKit::Action do
  it "names actions by scope, name and payload" do
    {
      DesktopKit::Action::Quit.new                                        => "app.quit",
      DesktopKit::Action::PresentSurface.new(7)                           => "app.present-surface(uint64 7)",
      DesktopKit::Action::DesktopNotification.new("Done", "Build passed") => "app.desktop-notification(('Done', 'Build passed'))",
      DesktopKit::Action::NewTab.new                                      => "win.new-tab",
      DesktopKit::Action::GotoTab.new(DesktopKit::Action::GotoTab::LAST)  => "win.goto-tab(-3)",
      DesktopKit::Action::CloseTab.new(:other)                            => "tab.close-tab::other",
      DesktopKit::Action::NewSplit.new(:right)                            => "split.new-split::right",
      DesktopKit::Action::ResizeSplit.new(:up, 10)                        => "split.resize-split(('up', uint32 10))",
      ActionSpecs::Paint.new(:dark_blue, 2)                               => "split.spec-paint(('dark_blue', 2))",
    }.each { |action, name| action.detailed_name.should eq name }
  end

  it "exposes the payload and the scope" do
    action = DesktopKit::Action::ResizeSplit.new(:left, 5)
    action.direction.should eq DesktopKit::Direction::Left
    action.amount.should eq 5
    action.name.should eq "resize-split"
    action.scope.should eq DesktopKit::Action::Scope::Split
    action.scope.prefix.should eq "split"
  end

  it "round-trips actions through their GAction parameter" do
    round_trip(DesktopKit::Action::Quit.new).should eq DesktopKit::Action::Quit.new
    round_trip(DesktopKit::Action::SizeLimit.new(1, 2, 3, 4)).should eq DesktopKit::Action::SizeLimit.new(1, 2, 3, 4)
    round_trip(DesktopKit::Action::SetWindowTheme.new(:dark)).should eq DesktopKit::Action::SetWindowTheme.new(:dark)
    round_trip(DesktopKit::Action::MouseVisibility.new(false)).should eq DesktopKit::Action::MouseVisibility.new(false)
    round_trip(ActionSpecs::Paint.new(:dark_blue, 3)).should eq ActionSpecs::Paint.new(:dark_blue, 3)
  end

  it "rejects parameters that do not carry the payload" do
    DesktopKit::Action::Quit.from_variant(DesktopKit::Variant.new(1)).should be_nil
    DesktopKit::Action::OpenUrl.from_variant(nil).should be_nil
    DesktopKit::Action::OpenUrl.from_variant(DesktopKit::Variant.new(1)).should be_nil
    DesktopKit::Action::CloseTab.from_variant(DesktopKit::Variant.new("left")).should be_nil
    ActionSpecs::Paint.from_variant(DesktopKit::Variant.new({"green", 1})).should be_nil
  end

  it "registers built-in and declared actions with their parameter types" do
    infos = DesktopKit::Action.registry.to_h { |info| {"#{info.scope.prefix}.#{info.name}", info.parameter_type} }
    infos["app.quit"].should be_nil
    infos["app.desktop-notification"].should eq "(ss)"
    infos["win.size-limit"].should eq "(uuuu)"
    infos["split.resize-split"].should eq "(su)"
    infos["app.spec-refresh"].should eq "b"
    infos["split.spec-paint"].should eq "(si)"
    infos.size.should eq DesktopKit::Action.registry.size
  end

  it "decodes parameters through the registry" do
    info = DesktopKit::Action.registry.find!(&.name.== "spec-paint")
    info.decode.call(DesktopKit::Variant.new({"red", 1})).should eq ActionSpecs::Paint.new(:red, 1)
    info.decode.call(nil).should be_nil
  end

  it "allows ipc only where declared" do
    ActionSpecs::Refresh.new(true).ipc?.should be_true
    DesktopKit::Action::NewWindow.new.ipc?.should be_true
    DesktopKit::Action::Quit.new.ipc?.should be_false
  end
end
