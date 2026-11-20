# spec/pure/ui/menu_spec.cr
require "../../spec_helper"

describe DesktopKit::Menu do
  it "builds sections and submenus" do
    menu = DesktopKit::Menu.build do |items|
      items.item "New Tab", DesktopKit::Action::NewTab.new
      items.section
      items.submenu "Split" do |split|
        split.item "Right", DesktopKit::Action::NewSplit.new(:right)
      end
    end
    menu.sections.map(&.map(&.label)).should eq [["New Tab"], ["Split"]]
    submenu = menu.sections[1][0].target.as(DesktopKit::Menu)
    submenu.sections[0][0].target.should eq DesktopKit::Action::NewSplit.new(:right)
  end

  it "starts no empty section" do
    menu = DesktopKit::Menu.new.section.section
    menu.sections.size.should eq 1
    menu.empty?.should be_true
    menu.item("New Window", DesktopKit::Action::NewWindow.new).empty?.should be_false
  end

  it "has a default window menu of window, split, title and close sections" do
    DesktopKit::Menu.window.sections.map(&.size).should eq [2, 4, 3, 2, 1]
  end
end
