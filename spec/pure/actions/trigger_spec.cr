# spec/pure/actions/trigger_spec.cr
require "../../spec_helper"

describe DesktopKit::Trigger do
  it "parses modifiers and keys" do
    {
      "ctrl+shift+t"   => {"shift+ctrl+t", "<Shift><Control>t", "SHIFT+CTRL+t", "Shift+Ctrl+T"},
      "Control+T"      => {"ctrl+t", "<Control>t", "CTRL+t", "Ctrl+T"},
      "cmd+opt+enter"  => {"alt+super+Return", "<Alt><Super>Return", "ALT+LOGO+Return", "Alt+Super+Return"},
      "ctrl++"         => {"ctrl+plus", "<Control>plus", "CTRL+plus", "Ctrl++"},
      "+"              => {"plus", "plus", "plus", "+"},
      "f5"             => {"F5", "F5", "F5", "F5"},
      "super+page_up"  => {"super+Page_Up", "<Super>Page_Up", "LOGO+Page_Up", "Super+Page Up"},
      "ctrl+KP_Enter"  => {"ctrl+KP_Enter", "<Control>KP_Enter", "CTRL+KP_Enter", "Ctrl+KP Enter"},
      "ctrl+€"         => {"ctrl+EuroSign", "<Control>EuroSign", "CTRL+EuroSign", "Ctrl+€"},
      "alt+arrow_left" => {"alt+Left", "<Alt>Left", "ALT+Left", "Alt+Left"},
    }.each do |text, (canonical, accel, xdg, label)|
      trigger = DesktopKit::Trigger.parse(text)
      trigger.to_s.should eq canonical
      trigger.to_gtk_accel.should eq accel
      trigger.to_xdg.should eq xdg
      trigger.label.should eq label
      DesktopKit::Trigger.parse(trigger.to_s).should eq trigger
    end
  end

  it "keeps the key lower case and the modifiers apart" do
    trigger = DesktopKit::Trigger.parse("ctrl+shift+T")
    trigger.keyval.should eq 't'.ord
    trigger.mods.should eq DesktopKit::Mods::Ctrl | DesktopKit::Mods::Shift
    trigger.should eq DesktopKit::Trigger.new('t'.ord.to_u32, DesktopKit::Mods.flags(Shift, Ctrl))
    trigger.inspect.should eq "Trigger(shift+ctrl+t)"
  end

  it "rejects text that is not a trigger" do
    {
      ""               => %(invalid trigger "": unknown key ""),
      "ctrl+"          => %(invalid trigger "ctrl+": unknown key ""),
      "+t"             => %(invalid trigger "+t": unknown modifier ""),
      "hyper+t"        => %(invalid trigger "hyper+t": unknown modifier "hyper"),
      "ctrl+control+t" => %(invalid trigger "ctrl+control+t": duplicate modifier "control"),
      "ctrl+nonsense"  => %(invalid trigger "ctrl+nonsense": unknown key "nonsense"),
      "shift+Shift_L"  => %(invalid trigger "shift+Shift_L": not a shortcut),
      "ctrl+😀"         => %(invalid trigger "ctrl+😀": not a shortcut),
    }.each do |text, message|
      expect_raises(ArgumentError, message) { DesktopKit::Trigger.parse(text) }
    end
  end

  it "rejects key values that cannot be shortcuts" do
    expect_raises(ArgumentError, /\Ainvalid trigger: key value 0xffe1/) { DesktopKit::Trigger.new(0xffe1_u32) }
  end
end

describe DesktopKit::Binding do
  it "parses its trigger and is local by default" do
    binding = DesktopKit::Binding.new("ctrl+q", DesktopKit::Action::Quit.new)
    binding.trigger.should eq DesktopKit::Trigger.parse("ctrl+q")
    binding.action.should eq DesktopKit::Action::Quit.new
    binding.global?.should be_false
    DesktopKit::Binding.new(binding.trigger, DesktopKit::Action::NewWindow.new, global: true).global?.should be_true
  end

  it "raises on an invalid trigger" do
    expect_raises(ArgumentError, %(invalid trigger "ctrl+nonsense")) { DesktopKit::Binding.new("ctrl+nonsense", DesktopKit::Action::Quit.new) }
  end

  it "parses trigger sequences" do
    binding = DesktopKit::Binding.new("ctrl+a>n", DesktopKit::Action::NewTab.new)
    binding.sequence?.should be_true
    binding.triggers.should eq [DesktopKit::Trigger.parse("ctrl+a"), DesktopKit::Trigger.parse("n")]
    binding.trigger.should eq DesktopKit::Trigger.parse("ctrl+a")
    binding.to_s.should eq "ctrl+a>n"
    binding.label.should eq "Ctrl+A N"
    DesktopKit::Binding.new("ctrl+q", DesktopKit::Action::Quit.new).sequence?.should be_false
  end

  it "keeps > as a key where no trigger ends before it" do
    DesktopKit::Binding.new("ctrl+>", DesktopKit::Action::Quit.new).triggers.should eq [DesktopKit::Trigger.parse("ctrl+>")]
    DesktopKit::Binding.new(">", DesktopKit::Action::Quit.new).triggers.should eq [DesktopKit::Trigger.parse(">")]
    DesktopKit::Binding.new("a>>", DesktopKit::Action::Quit.new).triggers.should eq [DesktopKit::Trigger.parse("a"), DesktopKit::Trigger.parse(">")]
    DesktopKit::Binding.new("ctrl+>>a", DesktopKit::Action::Quit.new).triggers.should eq [DesktopKit::Trigger.parse("ctrl+>"), DesktopKit::Trigger.parse("a")]
  end

  it "builds sequences from triggers" do
    triggers = [DesktopKit::Trigger.parse("ctrl+a"), DesktopKit::Trigger.parse("ctrl+b")]
    DesktopKit::Binding.new(triggers, DesktopKit::Action::Quit.new).to_s.should eq "ctrl+a>ctrl+b"
    expect_raises(ArgumentError, "empty binding") { DesktopKit::Binding.new([] of DesktopKit::Trigger, DesktopKit::Action::Quit.new) }
  end

  it "rejects global sequences" do
    expect_raises(ArgumentError, "sequences cannot be global") do
      DesktopKit::Binding.new("ctrl+a>n", DesktopKit::Action::NewWindow.new, global: true)
    end
  end

  it "raises on an invalid trigger in a sequence" do
    expect_raises(ArgumentError, %(invalid trigger "ctrl+nonsense")) { DesktopKit::Binding.new("ctrl+a>ctrl+nonsense", DesktopKit::Action::Quit.new) }
  end
end
