# examples/canvas.cr
#
# An OpenGL canvas that follows the pointer with its color, flashes on
# clicks, scrolls through brightness and shows the typed text in the title.
#
#   crystal run examples/canvas.cr
#
# Shift+Ctrl+O splits the canvas; Escape clears the text.
require "../src/desktop_kit"

@[Link("GL")]
lib LibGL
  COLOR_BUFFER_BIT = 0x4000_u32

  fun glClearColor(red : Float32, green : Float32, blue : Float32, alpha : Float32)
  fun glClear(mask : UInt32)
end

class Scene < DesktopKit::Canvas
  @red = 0.2
  @green = 0.2
  @brightness = 0.5
  @flash = false
  @text = ""

  def initialize
    super(api: :gl)
  end

  protected def on_render : Nil
    level = @flash ? 1.0 : @brightness
    LibGL.glClearColor((@red * level).to_f32, (@green * level).to_f32, level.to_f32 * 0.6_f32, 1.0_f32)
    LibGL.glClear(LibGL::COLOR_BUFFER_BIT)
  end

  protected def on_mouse_motion(event : DesktopKit::MouseMotionEvent) : Nil
    return if width == 0 || height == 0
    @red = (event.x / width).clamp(0.0, 1.0)
    @green = (event.y / height).clamp(0.0, 1.0)
    queue_render
  end

  protected def on_mouse_button(event : DesktopKit::MouseButtonEvent) : Nil
    @flash = event.pressed?
    queue_render
  end

  protected def on_scroll(event : DesktopKit::ScrollEvent) : Nil
    @brightness = (@brightness - event.dy * 0.05).clamp(0.1, 1.0)
    queue_render
  end

  protected def on_key(event : DesktopKit::KeyEvent) : Bool
    return false unless event.pressed? && event.keyval == 0xff1b_u32 # Escape
    self.text = ""
    true
  end

  protected def on_commit(text : String) : Nil
    self.text = @text + text
  end

  private def text=(@text : String) : Nil
    surface.title = @text.empty? ? "Canvas" : @text
  end
end

class CanvasApp < DesktopKit::App
  protected def new_surface(context : DesktopKit::SurfaceContext) : DesktopKit::Content
    Scene.new
  end

  protected def on_startup : Nil
    self.bindings = [
      DesktopKit::Binding.new("ctrl+shift+o", DesktopKit::Action::NewSplit.new(:right)),
      DesktopKit::Binding.new("ctrl+shift+w", DesktopKit::Action::CloseSurface.new),
    ]
  end

  protected def on_activate : Nil
    new_window
  end
end

exit CanvasApp.new("org.example.Canvas").run
