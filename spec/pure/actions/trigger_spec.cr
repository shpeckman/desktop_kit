# spec/pure/actions/trigger_spec.cr
require "../../spec_helper"

describe Apprt::Trigger do
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
      trigger = Apprt::Trigger.parse(text)
      trigger.to_s.should eq canonical
      trigger.to_gtk_accel.should eq accel
      trigger.to_xdg.should eq xdg
      trigger.label.should eq label
      Apprt::Trigger.parse(trigger.to_s).should eq trigger
    end
  end

  it "keeps the key lower case and the modifiers apart" do
    trigger = Apprt::Trigger.parse("ctrl+shift+T")
    trigger.keyval.should eq 't'.ord
    trigger.mods.should eq Apprt::Mods::Ctrl | Apprt::Mods::Shift
    trigger.should eq Apprt::Trigger.new('t'.ord.to_u32, Apprt::Mods.flags(Shift, Ctrl))
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
      expect_raises(ArgumentError, message) { Apprt::Trigger.parse(text) }
    end
  end

  it "rejects key values that cannot be shortcuts" do
    expect_raises(ArgumentError, /\Ainvalid trigger: key value 0xffe1/) { Apprt::Trigger.new(0xffe1_u32) }
  end
end

describe Apprt::Binding do
  it "parses its trigger and is local by default" do
    binding = Apprt::Binding.new("ctrl+q", Apprt::Action::Quit.new)
    binding.trigger.should eq Apprt::Trigger.parse("ctrl+q")
    binding.action.should eq Apprt::Action::Quit.new
    binding.global?.should be_false
    Apprt::Binding.new(binding.trigger, Apprt::Action::NewWindow.new, global: true).global?.should be_true
  end

  it "raises on an invalid trigger" do
    expect_raises(ArgumentError, %(invalid trigger "ctrl+nonsense")) { Apprt::Binding.new("ctrl+nonsense", Apprt::Action::Quit.new) }
  end

  it "parses trigger sequences" do
    binding = Apprt::Binding.new("ctrl+a>n", Apprt::Action::NewTab.new)
    binding.sequence?.should be_true
    binding.triggers.should eq [Apprt::Trigger.parse("ctrl+a"), Apprt::Trigger.parse("n")]
    binding.trigger.should eq Apprt::Trigger.parse("ctrl+a")
    binding.to_s.should eq "ctrl+a>n"
    binding.label.should eq "Ctrl+A N"
    Apprt::Binding.new("ctrl+q", Apprt::Action::Quit.new).sequence?.should be_false
  end

  it "keeps > as a key where no trigger ends before it" do
    Apprt::Binding.new("ctrl+>", Apprt::Action::Quit.new).triggers.should eq [Apprt::Trigger.parse("ctrl+>")]
    Apprt::Binding.new(">", Apprt::Action::Quit.new).triggers.should eq [Apprt::Trigger.parse(">")]
    Apprt::Binding.new("a>>", Apprt::Action::Quit.new).triggers.should eq [Apprt::Trigger.parse("a"), Apprt::Trigger.parse(">")]
    Apprt::Binding.new("ctrl+>>a", Apprt::Action::Quit.new).triggers.should eq [Apprt::Trigger.parse("ctrl+>"), Apprt::Trigger.parse("a")]
  end

  it "builds sequences from triggers" do
    triggers = [Apprt::Trigger.parse("ctrl+a"), Apprt::Trigger.parse("ctrl+b")]
    Apprt::Binding.new(triggers, Apprt::Action::Quit.new).to_s.should eq "ctrl+a>ctrl+b"
    expect_raises(ArgumentError, "empty binding") { Apprt::Binding.new([] of Apprt::Trigger, Apprt::Action::Quit.new) }
  end

  it "rejects global sequences" do
    expect_raises(ArgumentError, "sequences cannot be global") do
      Apprt::Binding.new("ctrl+a>n", Apprt::Action::NewWindow.new, global: true)
    end
  end

  it "raises on an invalid trigger in a sequence" do
    expect_raises(ArgumentError, %(invalid trigger "ctrl+nonsense")) { Apprt::Binding.new("ctrl+a>ctrl+nonsense", Apprt::Action::Quit.new) }
  end
end
