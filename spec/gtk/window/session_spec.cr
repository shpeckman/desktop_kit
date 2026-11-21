# spec/gtk/window/session_spec.cr
require "file_utils"
require "../harness"

# Content that saves the state it was created with, or its own once set.
private class StateContent < DesktopKit::WidgetContent
  property state : String?

  def initialize(@state : String?)
    super(DesktopKit::Widget.new(DesktopKit::C.gtk_entry_new))
  end

  protected def session_state : String?
    @state
  end
end

# Application of `StateContent` surfaces that restores its session when
# *restore*. A restore opens windows instead of activating, so `#steps`
# run once the first window's restore finished.
private class SessionApp < TestApp
  property steps : (TestApp ->)? = nil

  protected def on_window(window : DesktopKit::Window) : Nil
    steps = @steps || return
    @steps = nil
    DesktopKit::UIThread.post { steps.call(self) }
  end
end

private def session_app(id : String, restore : Bool = true) : SessionApp
  SessionApp.new(id).tap do |app|
    app.restore_session = restore
    app.make_content = ->(context : DesktopKit::SurfaceContext) { StateContent.new(context.session_state).as(DesktopKit::Content) }
  end
end

# Runs the block in *app* once its restored windows opened, then quits.
private def run_restored(app : SessionApp, &block : TestApp ->) : Nil
  failure = nil.as(Exception?)
  app.steps = ->(app : TestApp) do
    begin
      block.call(app)
    rescue ex
      failure = ex
    ensure
      app.quit
    end
  end
  run_app(app).should eq 0
  app.steps.should be_nil
  failure.try { |ex| raise ex }
end

# Returns the diagram of the active tab's split tree, surfaces unnamed.
private def layout(window : DesktopKit::Window) : String
  window.active_tab.not_nil!.@view.tree.to_diagram.gsub(/#<DesktopKit::Surface:0x[0-9a-f]+>/) { |name| " " * name.size }
end

private def state(surface : DesktopKit::Surface?) : String?
  surface.not_nil!.content.as(StateContent).state
end

private def split(window : DesktopKit::Window, direction : DesktopKit::Direction) : DesktopKit::Surface
  trigger(window, DesktopKit::Action::NewSplit.new(direction))
  window.active_surface.not_nil!
end

# Runs the block with `XDG_STATE_HOME` in a fresh directory.
private def with_state_home(&) : Nil
  dir = File.tempname("desktop-kit-session")
  Dir.mkdir_p(dir)
  saved = ENV["XDG_STATE_HOME"]?
  ENV["XDG_STATE_HOME"] = dir
  begin
    yield
  ensure
    saved ? (ENV["XDG_STATE_HOME"] = saved) : ENV.delete("XDG_STATE_HOME")
    FileUtils.rm_rf(dir)
  end
end

describe "App#restore_session?" do
  before_all { GtkHarness.start }

  it "reopens windows, tabs and splits with their states" do
    with_state_home do
      id = AppIds.next
      app = session_app(id)
      app.on_activated = ->(app : TestApp) do
        first = app.new_window
        first.active_surface.not_nil!.content.as(StateContent).state = "a"
        right = split(first, :right)
        right.content.as(StateContent).state = "b"
        right.title_override = "Bee"
        below = split(first, :down)
        below.content.as(StateContent).state = "c"
        tab = first.new_tab
        tab.title_override = "Second"
        tab.active_surface.not_nil!.content.as(StateContent).state = "d"
        trigger(first, DesktopKit::Action::GotoTab.new(0))
        app.new_window.active_surface.not_nil!.content.as(StateContent).state = "e"
        settle
        app.quit
      end
      run_app(app).should eq 0
      File.exists?(Path[ENV["XDG_STATE_HOME"], id, "session.json"]).should be_true

      restored = session_app(id)
      run_restored(restored) do
        restored.events.should_not contain("activate")
        windows = restored.windows
        windows.size.should eq 2
        first, second = windows
        first.tabs.size.should eq 2
        first.active_tab.should eq first.tabs[0]
        tab = first.tabs[0]
        tab.surfaces.map { |surface| state(surface) }.should eq ["a", "b", "c"]
        tab.surfaces[1].title_override.should eq "Bee"
        state(tab.active_surface).should eq "c"
        diagram = tab.@view.tree.to_diagram
        first.tabs[1].title_override.should eq "Second"
        first.tabs[1].surfaces.map { |surface| state(surface) }.should eq ["d"]
        second.tabs.flat_map(&.surfaces).map { |surface| state(surface) }.should eq ["e"]
        restored.contexts.map(&.kind).uniq.should eq [DesktopKit::SurfaceContext::Kind::Restore]
        diagram.should_not be_empty
      end
    end
  end

  it "keeps split layouts and ratios" do
    with_state_home do
      id = AppIds.next
      app = session_app(id)
      before = ""
      app.on_activated = ->(app : TestApp) do
        window = app.new_window
        split(window, :right)
        split(window, :down)
        trigger(window, DesktopKit::Action::ResizeSplit.new(:left, 100))
        before = layout(window)
        app.quit
      end
      run_app(app)
      restored = session_app(id)
      run_restored(restored) do
        layout(restored.windows.first).should eq before
      end
    end
  end

  it "reopens floats with their bounds, titles and focus" do
    with_state_home do
      id = AppIds.next
      app = session_app(id)
      app.on_activated = ->(app : TestApp) do
        window = app.new_window
        window.active_surface.not_nil!.content.as(StateContent).state = "a"
        right = split(window, :right)
        right.content.as(StateContent).state = "b"
        below = split(window, :down)
        below.content.as(StateContent).state = "c"
        below.title_override = "Sea"
        right.float(DesktopKit::Bounds.new(0.1, 0.2, 0.5, 0.4)).should be_true
        below.float(DesktopKit::Bounds.new(0.3, 0.1, 0.25, 0.5)).should be_true
        settle
        app.quit
      end
      run_app(app).should eq 0
      File.read(Path[ENV["XDG_STATE_HOME"], id, "session.json"]).should contain(%("floats"))

      restored = session_app(id)
      run_restored(restored) do
        tab = restored.windows.first.tabs.first
        tab.surfaces.map { |surface| state(surface) }.should eq ["a", "b", "c"]
        tab.floats.map { |surface| state(surface) }.should eq ["b", "c"]
        right, below = tab.floats
        state(tab.active_surface).should eq "c"
        below.title_override.should eq "Sea"
        {right, below}.zip({DesktopKit::Bounds.new(0.1, 0.2, 0.5, 0.4), DesktopKit::Bounds.new(0.3, 0.1, 0.25, 0.5)}) do |surface, expected|
          bounds = surface.float_bounds.not_nil!
          {bounds.x, bounds.y, bounds.width, bounds.height}.zip({expected.x, expected.y, expected.width, expected.height}) do |value, want|
            value.should be_close(want, 1e-9)
          end
        end
        eventually { below.@host.mapped? }.should be_true
      end
    end
  end

  it "reads and writes sessions without floats as before" do
    with_state_home do
      id = AppIds.next
      file = Path[ENV["XDG_STATE_HOME"], id, "session.json"]
      Dir.mkdir_p(file.parent)
      content = %({"version":1,"windows":[{"width":640,"height":480,"maximized":false,"fullscreen":false,"selected":0,"tabs":[{"root":{"state":"x","active":true,"zoomed":false}}]}]})
      DesktopKit::Session::Data.from_json(content).to_json.should eq content
      File.write(file, content)
      app = session_app(id)
      run_restored(app) do
        tab = app.windows.first.tabs.first
        tab.surfaces.map { |surface| state(surface) }.should eq ["x"]
        tab.floats.should be_empty
      end
      saved = File.read(file)
      saved.should contain(%("state":"x"))
      saved.should_not contain(%("floats"))
    end
  end

  it "ignores a session with floats outside the tab" do
    with_state_home do
      [%({"x":0.1,"y":0.1,"width":0.0,"height":0.5}), %({"x":0.6,"y":0.1,"width":0.5,"height":0.5})].each do |bounds|
        id = AppIds.next
        file = Path[ENV["XDG_STATE_HOME"], id, "session.json"]
        Dir.mkdir_p(file.parent)
        float = %({"surface":{"state":"f","active":false,"zoomed":false},) + bounds[1..]
        File.write(file, %({"version":1,"windows":[{"width":0,"height":0,"maximized":false,"fullscreen":false,"selected":0,"tabs":[{"root":{"state":"x","active":true,"zoomed":false},"floats":[#{float}]}]}]}))
        app = session_app(id)
        run_app(app)
        app.events.should contain("activate")
        app.contexts.should be_empty
      end
    end
  end

  it "reopens stacks with their order, shown surface and focus" do
    with_state_home do
      id = AppIds.next
      app = session_app(id)
      app.on_activated = ->(app : TestApp) do
        window = app.new_window
        window.active_surface.not_nil!.content.as(StateContent).state = "a"
        right = split(window, :right)
        right.content.as(StateContent).state = "b"
        below = split(window, :down)
        below.content.as(StateContent).state = "c"
        below.title_override = "Sea"
        below.stack_into(:up).should be_true
        right.focus
        settle
        app.quit
      end
      run_app(app).should eq 0
      saved = File.read(Path[ENV["XDG_STATE_HOME"], id, "session.json"])
      saved.should contain(%("state":"b","active":true,"zoomed":false,"stack":[{"state":"c","title":"Sea","active":false,"zoomed":false}],"index":0))

      restored = session_app(id)
      run_restored(restored) do
        tab = restored.windows.first.tabs.first
        tab.surfaces.map { |surface| state(surface) }.should eq ["a", "b", "c"]
        right = tab.surfaces[1]
        below = tab.surfaces[2]
        right.stack.should eq [right, below]
        below.title_override.should eq "Sea"
        tab.active_surface.should eq right
        eventually { right.@host.mapped? }.should be_true
        below.@host.visible?.should be_false
      end
    end
  end

  it "shows a stacked surface saved as focused" do
    with_state_home do
      id = AppIds.next
      file = Path[ENV["XDG_STATE_HOME"], id, "session.json"]
      Dir.mkdir_p(file.parent)
      File.write(file, %({"version":1,"windows":[{"width":0,"height":0,"maximized":false,"fullscreen":false,"selected":0,"tabs":[{"root":{"state":"x","active":false,"zoomed":false,"stack":[{"state":"y","active":true,"zoomed":false}],"index":0}}]}]}))
      app = session_app(id)
      run_restored(app) do
        tab = app.windows.first.tabs.first
        tab.surfaces.map { |surface| state(surface) }.should eq ["x", "y"]
        state(tab.active_surface).should eq "y"
        hidden, shown = tab.surfaces
        eventually { shown.@host.mapped? }.should be_true
        hidden.@host.visible?.should be_false
      end
    end
  end

  it "ignores a session with a stack index outside the stack" do
    with_state_home do
      id = AppIds.next
      file = Path[ENV["XDG_STATE_HOME"], id, "session.json"]
      Dir.mkdir_p(file.parent)
      File.write(file, %({"version":1,"windows":[{"width":0,"height":0,"maximized":false,"fullscreen":false,"selected":0,"tabs":[{"root":{"state":"x","active":true,"zoomed":false,"stack":[{"state":"y","active":false,"zoomed":false}],"index":2}}]}]}))
      app = session_app(id)
      run_app(app)
      app.events.should contain("activate")
      app.contexts.should be_empty
    end
  end

  it "activates as usual without a saved session or when disabled" do
    with_state_home do
      id = AppIds.next
      app = session_app(id, restore: false)
      app.on_activated = ->(app : TestApp) { app.new_window; app.quit }
      run_app(app)
      File.exists?(Path[ENV["XDG_STATE_HOME"], id, "session.json"]).should be_false
      fresh = session_app(id)
      run_app(fresh)
      fresh.events.should contain("activate")
    end
  end

  it "ignores a corrupt session file" do
    with_state_home do
      id = AppIds.next
      file = Path[ENV["XDG_STATE_HOME"], id, "session.json"]
      Dir.mkdir_p(file.parent)
      File.write(file, %({"version":1,"windows":[{"width":0,"height":0,"maximized":false,"fullscreen":false,"selected":0,"tabs":[{"title":null,"root":{"layout":"horizontal","ratio":2.0}}]}]}))
      app = session_app(id)
      run_app(app)
      app.events.should contain("activate")
      app.contexts.should be_empty
    end
  end

  it "forgets the session when the last window closes" do
    with_state_home do
      id = AppIds.next
      app = session_app(id)
      app.quit_delay = nil
      file = Path[ENV["XDG_STATE_HOME"], id, "session.json"]
      app.on_activated = ->(app : TestApp) do
        window = app.new_window
        app.quit
      end
      run_app(app)
      File.exists?(file).should be_true
      again = session_app(id)
      again.quit_delay = nil
      run_restored(again) do
        again.windows.size.should eq 1
        again.windows.first.close
        eventually { again.windows.empty? }.should be_true
        File.exists?(file).should be_false
      end
    end
  end
end
