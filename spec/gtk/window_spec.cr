# spec/gtk/window_spec.cr
require "./harness"

private def host(surface : Apprt::Surface) : Apprt::Widget
  surface.content.widget.parent.not_nil!
end

private def paned?(widget : Apprt::Widget?) : Bool
  !widget.nil? && Apprt::C.g_type_check_instance_is_a(widget, Apprt::C.gtk_paned_get_type) != 0
end

private def orientation(paned : Apprt::Widget) : Apprt::C::GtkOrientation
  Apprt::C.gtk_orientable_get_orientation(paned)
end

private def start_child(paned : Apprt::Widget) : Apprt::Widget?
  Apprt::Widget.new?(Apprt::C.gtk_paned_get_start_child(paned))
end

private def end_child(paned : Apprt::Widget) : Apprt::Widget?
  Apprt::Widget.new?(Apprt::C.gtk_paned_get_end_child(paned))
end

# Returns whether the pane holding *surface* has its position from the split
# ratio.
private def divided?(surface : Apprt::Surface) : Bool
  paned = surface.content.widget.parent.try(&.parent)
  return false unless paned?(paned)
  value = Apprt::C::GValue.new
  Apprt::C.g_value_init(pointerof(value), 20_u64) # G_TYPE_BOOLEAN
  Apprt::C.g_object_get_property(paned.not_nil!, "position-set", pointerof(value))
  Apprt::C.g_value_get_boolean(pointerof(value)) != 0
end

# Returns the divider position of the pane holding *surface*.
private def position(surface : Apprt::Surface) : Int32
  Apprt::C.gtk_paned_get_position(host(surface).parent.not_nil!)
end

private def dialog(window : Apprt::Window) : Void*
  Apprt::C.adw_application_window_get_visible_dialog(window.widget)
end

private def heading(window : Apprt::Window) : String?
  dialog = dialog(window)
  Apprt::Native.string?(Apprt::C.adw_alert_dialog_get_heading(dialog)) unless dialog.null?
end

# Closes the visible dialog of *window* with *response*.
private def respond(window : Apprt::Window, response : String) : Nil
  dialog = dialog(window)
  dialog.null?.should be_false
  Apprt::C.adw_alert_dialog_set_close_response(dialog, response)
  Apprt::C.adw_dialog_force_close(dialog)
  settle
end

private def default_title : String
  Apprt::Native.string?(Apprt::C.g_get_application_name) || ""
end

describe Apprt::Window do
  before_all { GtkHarness.start }

  it "opens with one tab showing one surface" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      app.windows.should eq [window]
      app.active_window.should eq window
      tab = window.tabs.first
      window.tabs.size.should eq 1
      window.active_tab.should eq tab
      tab.window.should eq window
      surface = tab.surfaces.first
      tab.surfaces.size.should eq 1
      tab.active_surface.should eq surface
      app.active_surface.should eq surface
      surface.tab.should eq tab
      surface.window.should eq window
      app.surface(surface.id).should eq surface
      app.contexts.map(&.kind).should eq [Apprt::SurfaceContext::Kind::Window]
      app.contexts.first.parent.should be_nil
      paned?(host(surface).parent).should be_false
    end
  end

  it "raises off the GTK thread" do
    expect_raises(RuntimeError, "GTK called outside the UI thread") { TestApp.new.new_window }
  end

  it "opens tabs after the selected tab and from its surface" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      first = window.tabs.first
      second = window.new_tab
      third = window.new_tab
      settle
      window.tabs.should eq [first, second, third]
      window.active_tab.should eq third
      trigger(window, Apprt::Action::GotoTab.new(0))
      window.active_tab.should eq first
      fourth = window.new_tab
      window.tabs.should eq [first, fourth, second, third]
      app.contexts.map(&.kind).should eq [
        Apprt::SurfaceContext::Kind::Window,
        Apprt::SurfaceContext::Kind::Tab,
        Apprt::SurfaceContext::Kind::Tab,
        Apprt::SurfaceContext::Kind::Tab,
      ]
      app.contexts.last.parent.should eq first.active_surface
    end
  end

  it "selects tabs by index, wrapping the previous and next tab" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      first = window.tabs.first
      second = window.new_tab
      third = window.new_tab
      settle
      trigger(window, Apprt::Action::GotoTab.new(Apprt::Action::GotoTab::NEXT))
      window.active_tab.should eq first
      trigger(window, Apprt::Action::GotoTab.new(Apprt::Action::GotoTab::PREVIOUS))
      window.active_tab.should eq third
      trigger(window, Apprt::Action::GotoTab.new(1))
      window.active_tab.should eq second
      trigger(window, Apprt::Action::GotoTab.new(Apprt::Action::GotoTab::LAST))
      window.active_tab.should eq third
      trigger(window, Apprt::Action::GotoTab.new(0))
      trigger(window, Apprt::Action::GotoTab.new(10))
      window.active_tab.should eq third
    end
  end

  it "moves tabs, wrapping around the ends" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      first = window.tabs.first
      second = window.new_tab
      third = window.new_tab
      settle
      trigger(window, Apprt::Action::MoveTab.new(1))
      window.tabs.should eq [third, first, second]
      trigger(window, Apprt::Action::MoveTab.new(-1))
      window.tabs.should eq [first, second, third]
      trigger(window, Apprt::Action::MoveTab.new(-1))
      window.tabs.should eq [first, third, second]
      window.active_tab.should eq third
    end
  end

  it "moves a tab to a new window" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      first = window.tabs.first
      second = window.new_tab
      settle
      trigger(window, Apprt::Action::MoveTabToNewWindow.new)
      app.windows.size.should eq 2
      other = app.windows.last
      window.tabs.should eq [first]
      other.tabs.should eq [second]
      second.window.should eq other
      second.active_surface.not_nil!.window.should eq other
      trigger(other, Apprt::Action::MoveTabToNewWindow.new)
      app.windows.size.should eq 2
    end
  end

  it "closes other tabs and the tabs after the selected one" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      first = window.tabs.first
      second = window.new_tab
      third = window.new_tab
      settle
      trigger(window, Apprt::Action::GotoTab.new(0))
      trigger(window, Apprt::Action::CloseTab.new(:right))
      window.tabs.should eq [first]
      second.closed?.should be_true
      third.closed?.should be_true
      second.window.should be_nil
      fourth = window.new_tab
      settle
      trigger(window, Apprt::Action::CloseTab.new(:other))
      window.tabs.should eq [fourth]
      first.closed?.should be_true
    end
  end

  it "closes with its last tab" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      surface = window.active_surface.not_nil!
      settle
      trigger(window, Apprt::Action::CloseTab.new(:this))
      window.closed?.should be_true
      surface.closed?.should be_true
      app.windows.should be_empty
      app.surface(surface.id).should be_nil
      expect_raises(RuntimeError, "the window is closed") { window.new_tab }
    end
  end

  it "opens new windows from the active surface" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      surface = window.active_surface
      settle
      Apprt::C.g_action_group_activate_action(app.to_unsafe, "new-window", Pointer(Void).null)
      settle
      app.windows.size.should eq 2
      app.contexts.last.kind.window?.should be_true
      app.contexts.last.parent.should eq surface
    end
  end

  it "closes every window" do
    app = TestApp.new
    run_steps(app) do
      first = app.new_window
      second = app.new_window
      settle
      Apprt::C.g_action_group_activate_action(app.to_unsafe, "close-all-windows", Pointer(Void).null)
      settle
      first.closed?.should be_true
      second.closed?.should be_true
      app.windows.should be_empty
    end
  end

  it "shows the titles the user chose before the surface titles" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      surface = tab.surfaces.first
      settle
      tab.title.should eq default_title
      surface.title = "shell"
      tab.title.should eq "shell"
      window.title.should eq "shell"
      Apprt::Native.string?(Apprt::C.gtk_window_get_title(window.widget)).should eq "shell"
      trigger(window, Apprt::Action::SetTitle.new("vim"))
      surface.title.should eq "vim"
      surface.title_override = "mine"
      tab.title.should eq "mine"
      tab.title_override = "tab"
      tab.title.should eq "tab"
      window.title.should eq "tab"
      trigger(window, Apprt::Action::SetWindowTitle.new("window"))
      window.title.should eq "window"
      Apprt::Native.string?(Apprt::C.gtk_window_get_title(window.widget)).should eq "window"
      window.title_override = nil
      window.title.should eq "tab"
      trigger(window, Apprt::Action::SetTabTitle.new("other"))
      tab.title.should eq "other"
      tab.title_override = nil
      tab.title.should eq "mine"
      surface.title_override = nil
      tab.title.should eq "vim"
    end
  end

  it "asks for titles" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      surface = tab.surfaces.first
      settle
      trigger(window, Apprt::Action::PromptTitle.new(:tab))
      heading(window).should eq "Change Tab Title"
      respond(window, "cancel")
      tab.title_override.should be_nil
      trigger(window, Apprt::Action::PromptTitle.new(:surface))
      heading(window).should eq "Change Surface Title"
      respond(window, "cancel")
      surface.title_override.should be_nil
      trigger(window, Apprt::Action::PromptTitle.new(:window))
      heading(window).should eq "Change Window Title"
      entry = Apprt::C.adw_alert_dialog_get_extra_child(dialog(window))
      Apprt::C.gtk_editable_set_text(entry, "  custom  ")
      respond(window, "ok")
      window.title_override.should eq "custom"
      window.title.should eq "custom"
      trigger(window, Apprt::Action::PromptTitle.new(:window))
      Apprt::C.gtk_editable_set_text(Apprt::C.adw_alert_dialog_get_extra_child(dialog(window)), " ")
      respond(window, "ok")
      window.title_override.should be_nil
    end
  end

  it "asks before closing a window with a surface that confirms closing" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      window.active_surface.not_nil!.confirm_close = true
      settle
      window.close
      heading(window).should eq "Close Window?"
      respond(window, "cancel")
      window.closed?.should be_false
      window.close
      respond(window, "close")
      window.closed?.should be_true
      app.windows.should be_empty
    end
  end

  it "asks before closing a tab with a surface that confirms closing" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      first = window.tabs.first
      second = window.new_tab
      second.active_surface.not_nil!.confirm_close = true
      settle
      second.close
      settle
      heading(window).should eq "Close Tab?"
      respond(window, "cancel")
      second.closed?.should be_false
      window.tabs.should eq [first, second]
      second.close
      settle
      respond(window, "close")
      second.closed?.should be_true
      window.tabs.should eq [first]
      first.close
      settle
      window.closed?.should be_true
    end
  end

  it "asks before quitting with a surface that confirms closing" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      window.active_surface.not_nil!.confirm_close = true
      settle
      Apprt::C.g_action_group_activate_action(app.to_unsafe, "quit", Pointer(Void).null)
      settle
      heading(window).should eq "Quit?"
      respond(window, "cancel")
      app.running?.should be_true
      window.closed?.should be_false
    end
  end
end

describe Apprt::Tab do
  before_all { GtkHarness.start }

  it "splits surfaces into nested panes" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      first = tab.surfaces.first
      settle
      root = host(first).parent.not_nil!
      second = first.split(:right)
      settle
      outer = host(first).parent.not_nil!
      paned?(outer).should be_true
      outer.parent.should eq root
      orientation(outer).should eq Apprt::C::GtkOrientation::Horizontal
      start_child(outer).should eq host(first)
      end_child(outer).should eq host(second)

      third = second.split(:down)
      settle
      inner = host(second).parent.not_nil!
      paned?(inner).should be_true
      outer = host(first).parent.not_nil!
      outer.parent.should eq root
      inner.parent.should eq outer
      orientation(inner).should eq Apprt::C::GtkOrientation::Vertical
      start_child(inner).should eq host(second)
      end_child(inner).should eq host(third)

      fourth = first.split(:left)
      settle
      start_child(host(first).parent.not_nil!).should eq host(fourth)

      tab.surfaces.should eq [fourth, first, second, third]
      tab.active_surface.should eq fourth
      app.contexts.map(&.kind).should eq [
        Apprt::SurfaceContext::Kind::Window,
        Apprt::SurfaceContext::Kind::Split,
        Apprt::SurfaceContext::Kind::Split,
        Apprt::SurfaceContext::Kind::Split,
      ]
      app.contexts[2].parent.should eq second
      third.tab.should eq tab
    end
  end

  it "splits through the split actions" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      first = tab.surfaces.first
      settle
      trigger(window, Apprt::Action::NewSplit.new(:down))
      second = tab.active_surface.not_nil!
      tab.surfaces.should eq [first, second]
      orientation(host(first).parent.not_nil!).should eq Apprt::C::GtkOrientation::Vertical
    end
  end

  it "splits a tab in half, resizes the split and keeps dragged dividers" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      first = window.tabs.first.surfaces.first
      settle
      second = first.split(:right)
      settle
      eventually { divided?(first) }.should be_true
      (host(first).width - host(second).width).abs.should be <= 8
      before = position(first)
      first.focus
      trigger(window, Apprt::Action::ResizeSplit.new(:right, 80_u32))
      eventually { divided?(first) && (position(first) - before - 80).abs <= 4 }.should be_true
      trigger(window, Apprt::Action::ResizeSplit.new(:left, 40_u32))
      eventually { divided?(first) && (position(first) - before - 40).abs <= 4 }.should be_true
      trigger(window, Apprt::Action::EqualizeSplits.new)
      eventually { divided?(first) && (position(first) - before).abs <= 4 }.should be_true

      Apprt::C.gtk_paned_set_position(host(first).parent.not_nil!, before + 100)
      settle
      second.split(:down)
      eventually { paned?(host(second).parent) && divided?(first) && (position(first) - before - 100).abs <= 4 }.should be_true
    end
  end

  it "moves the focus between surfaces" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      first = tab.surfaces.first
      second = first.split(:right)
      third = second.split(:down)
      settle
      tab.active_surface.should eq third
      trigger(window, Apprt::Action::GotoSplit.new(:left))
      tab.active_surface.should eq first
      trigger(window, Apprt::Action::GotoSplit.new(:previous))
      tab.active_surface.should eq third
      trigger(window, Apprt::Action::GotoSplit.new(:next))
      tab.active_surface.should eq first
      trigger(window, Apprt::Action::GotoSplit.new(:right))
      tab.active_surface.should eq second
      second.focus
      third.focus
      tab.active_surface.should eq third
      app.active_surface.should eq third
    end
  end

  it "tracks the surface the keyboard focus moves into" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      first = tab.surfaces.first
      second = first.split(:right)
      settle
      tab.active_surface.should eq second
      Apprt::C.gtk_widget_grab_focus(first.content.widget)
      settle
      tab.active_surface.should eq first
    end
  end

  it "zooms a surface to fill the tab" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      first = tab.surfaces.first
      settle
      root = host(first).parent.not_nil!
      second = first.split(:right)
      second.title = "shell"
      settle
      trigger(window, Apprt::Action::ToggleSplitZoom.new)
      tab.zoomed?.should be_true
      tab.title.should eq "🔍 shell"
      host(second).parent.should eq root
      first.content.widget.parent.try(&.parent).should be_nil
      trigger(window, Apprt::Action::ToggleSplitZoom.new)
      tab.zoomed?.should be_false
      tab.title.should eq "shell"
      paned?(host(first).parent).should be_true

      trigger(window, Apprt::Action::ToggleSplitZoom.new)
      first.focus
      settle
      tab.zoomed?.should be_false
      tab.active_surface.should eq first
      paned?(host(second).parent).should be_true
    end
  end

  it "closes a surface and focuses its neighbour" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      first = tab.surfaces.first
      settle
      root = host(first).parent.not_nil!
      second = first.split(:right)
      third = second.split(:down)
      settle
      trigger(window, Apprt::Action::CloseSurface.new)
      third.closed?.should be_true
      app.surface(third.id).should be_nil
      tab.surfaces.should eq [first, second]
      tab.active_surface.should eq second
      second.close
      settle
      tab.surfaces.should eq [first]
      tab.active_surface.should eq first
      host(first).parent.should eq root
      expect_raises(RuntimeError, "the surface is closed") { second.split(:left) }
      first.close
      settle
      tab.closed?.should be_true
      window.closed?.should be_true
    end
  end

  it "asks before closing a surface that confirms closing" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      first = tab.surfaces.first
      first.confirm_close = true
      second = first.split(:right)
      settle
      first.close
      heading(window).should eq "Close Split?"
      respond(window, "cancel")
      first.closed?.should be_false
      first.close
      respond(window, "close")
      first.closed?.should be_true
      tab.surfaces.should eq [second]
      second.confirm_close = true
      second.close
      heading(window).should eq "Close Tab?"
      respond(window, "close")
      window.closed?.should be_true
    end
  end
end
