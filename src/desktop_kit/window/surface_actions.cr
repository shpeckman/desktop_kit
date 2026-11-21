# src/desktop_kit/window/surface_actions.cr
module DesktopKit
  abstract class App
    protected def perform(target : Surface, action : Action::CopyTitleToClipboard) : Bool
      title = target.shown_title || return false
      Clipboard.write(title)
      true
    end

    protected def perform(target : Surface, action : Action::ToggleReadOnly) : Bool
      target.read_only = !target.read_only?
      true
    end

    protected def perform(target : Surface, action : Action::ShowOnScreenKeyboard) : Bool
      target.show_on_screen_keyboard
    end

    protected def perform(target : Surface, action : Action::StartSearch) : Bool
      target.start_search
      true
    end

    protected def perform(target : Surface, action : Action::EndSearch) : Bool
      return false unless target.search_active?
      target.end_search
      true
    end

    protected def perform(target : Surface, action : Action::Search) : Bool
      target.start_search(action.needle)
      true
    end

    protected def perform(target : Surface, action : Action::NavigateSearch) : Bool
      return false unless target.search_active?
      target.navigate_search(action.direction.next?)
      true
    end

    protected def perform(target : Surface, action : Action::NewSplit) : Bool
      target.split(action.direction)
      true
    end

    protected def perform(target : Surface, action : Action::GotoSplit) : Bool
      target.tab.try(&.goto(target, action.direction)) || false
    end

    protected def perform(target : Surface, action : Action::SwapSplit) : Bool
      target.tab.try(&.swap(target, action.direction)) || false
    end

    protected def perform(target : Surface, action : Action::MoveSurfaceToNewWindow) : Bool
      target.tab.try(&.window).try(&.move_surface_to_new_window(target)) || false
    end

    protected def perform(target : Surface, action : Action::MoveSurfaceToPreviousWindow) : Bool
      window = target.tab.try(&.window) || return false
      previous = previous_window(window) || return false
      window.move_surface(target, previous)
    end

    protected def perform(target : Surface, action : Action::ResizeSplit) : Bool
      target.tab.try(&.resize(target, action.direction, action.amount)) || false
    end

    protected def perform(target : Surface, action : Action::EqualizeSplits) : Bool
      target.tab.try(&.equalize) || false
    end

    protected def perform(target : Surface, action : Action::ToggleSplitZoom) : Bool
      target.tab.try(&.toggle_zoom(target)) || false
    end

    protected def perform(target : Surface, action : Action::ToggleFloat) : Bool
      target.floating? ? target.tile : target.float
    end

    protected def perform(target : Surface, action : Action::MoveFloat) : Bool
      target.tab.try(&.move_float(target, action.direction, action.amount)) || false
    end

    protected def perform(target : Surface, action : Action::StackInto) : Bool
      target.stack_into(action.direction)
    end

    protected def perform(target : Surface, action : Action::Unstack) : Bool
      target.unstack(action.layout)
    end

    protected def perform(target : Surface, action : Action::GotoStacked) : Bool
      target.tab.try(&.goto_stacked(target, action.index)) || false
    end

    protected def perform(target : Surface, action : Action::CloseSurface) : Bool
      target.close
      true
    end

    protected def perform(target : Surface, action : Action::SetTitle) : Bool
      target.title = action.title
      true
    end

    protected def perform(target : Surface, action : Action::RingBell) : Bool
      target.ring_bell
      true
    end

    protected def perform(target : Surface, action : Action::MouseVisibility) : Bool
      target.mouse_visible = action.visible
      true
    end

    protected def perform(target : Surface, action : Action::PromptTitle) : Bool
      kind = action.kind
      case kind
      in .surface?
        Dialogs.prompt_title(target.host, kind, target.title_override) { |title| target.title_override = title }
      in .tab?
        tab = target.tab || return false
        Dialogs.prompt_title(target.host, kind, tab.title_override) { |title| tab.title_override = title }
      in .window?
        window = target.window || return false
        Dialogs.prompt_title(target.host, kind, window.title_override) { |title| window.title_override = title }
      end
      true
    end
  end
end
