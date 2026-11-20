# src/desktop_kit/glib/widget.cr
module DesktopKit
  # A borrowed handle to a GTK widget.
  #
  # A `Widget` holds no reference: GTK owns the widget tree and destroys a
  # widget when its parent drops it. A handle stays valid while the widget is
  # part of a window or while something else keeps it alive. Use it on the
  # GTK thread only.
  struct Widget
    getter to_unsafe : Void*

    # Wraps the `GtkWidget*` *pointer*; raises `ArgumentError` when it is null.
    def initialize(@to_unsafe : Void*)
      raise ArgumentError.new("Widget: null pointer") if @to_unsafe.null?
    end

    # Returns a handle to *pointer*, or `nil` when it is null.
    def self.new?(pointer : Void*) : self?
      new(pointer) unless pointer.null?
    end

    def parent : Widget?
      Widget.new?(C.gtk_widget_get_parent(self))
    end

    # Returns the toplevel widget, usually a window, or `nil` while the widget
    # is not in one.
    def root : Widget?
      Widget.new?(C.gtk_widget_get_root(self))
    end

    def width : Int32
      C.gtk_widget_get_width(self)
    end

    def height : Int32
      C.gtk_widget_get_height(self)
    end

    # Returns the integer scale of the monitor the widget is on.
    def scale_factor : Int32
      C.gtk_widget_get_scale_factor(self)
    end

    def realized? : Bool
      C.gtk_widget_get_realized(self) != 0
    end

    def mapped? : Bool
      C.gtk_widget_get_mapped(self) != 0
    end

    def visible? : Bool
      C.gtk_widget_get_visible(self) != 0
    end

    def visible=(visible : Bool) : Bool
      C.gtk_widget_set_visible(self, visible ? 1 : 0)
      visible
    end

    def hexpand=(expand : Bool) : Bool
      C.gtk_widget_set_hexpand(self, expand ? 1 : 0)
      expand
    end

    def vexpand=(expand : Bool) : Bool
      C.gtk_widget_set_vexpand(self, expand ? 1 : 0)
      expand
    end

    # Sets the minimum size; -1 leaves a dimension at its natural size.
    def size_request(width : Int32, height : Int32) : Nil
      C.gtk_widget_set_size_request(self, width, height)
    end

    def focusable=(focusable : Bool) : Bool
      C.gtk_widget_set_focusable(self, focusable ? 1 : 0)
      focusable
    end

    # Moves the keyboard focus to the widget; returns `false` when it cannot
    # take the focus.
    def grab_focus : Bool
      C.gtk_widget_grab_focus(self) != 0
    end

    # Returns `true` when the widget has the keyboard focus in an active
    # window.
    def focus? : Bool
      C.gtk_widget_has_focus(self) != 0
    end

    # Sets the pointer cursor by CSS cursor *name* (`"text"`, `"pointer"`);
    # `nil` restores the default.
    def cursor_name=(name : String?) : String?
      C.gtk_widget_set_cursor_from_name(self, Native.string(name))
      name
    end

    def tooltip=(text : String?) : String?
      C.gtk_widget_set_tooltip_text(self, Native.string(text))
      text
    end

    def add_css_class(name : String) : Nil
      C.gtk_widget_add_css_class(self, name)
    end

    def remove_css_class(name : String) : Nil
      C.gtk_widget_remove_css_class(self, name)
    end

    # Schedules a redraw.
    def queue_draw : Nil
      C.gtk_widget_queue_draw(self)
    end

    protected def unparent : Nil
      C.gtk_widget_unparent(self)
    end

    protected def native : Widget?
      Widget.new?(C.gtk_widget_get_native(self))
    end

    protected def display : Void*
      C.gtk_widget_get_display(self)
    end

    protected def ancestor(type : C::GType) : Widget?
      Widget.new?(C.gtk_widget_get_ancestor(self, type))
    end

    protected def focus_on_click=(value : Bool) : Bool
      C.gtk_widget_set_focus_on_click(self, value ? 1 : 0)
      value
    end

    protected def can_focus=(value : Bool) : Bool
      C.gtk_widget_set_can_focus(self, value ? 1 : 0)
      value
    end

    protected def cursor=(cursor : Void*) : Void*
      C.gtk_widget_set_cursor(self, cursor)
      cursor
    end

    protected def name=(name : String) : String
      C.gtk_widget_set_name(self, name)
      name
    end

    protected def add_controller(controller : Void*) : Nil
      C.gtk_widget_add_controller(self, controller)
    end

    protected def remove_controller(controller : Void*) : Nil
      C.gtk_widget_remove_controller(self, controller)
    end

    protected def insert_action_group(prefix : String, group : Void*) : Nil
      C.gtk_widget_insert_action_group(self, prefix, group)
    end

    protected def activate_action(name : String, parameter : Variant? = nil) : Bool
      C.gtk_widget_activate_action_variant(self, name, parameter.try(&.to_unsafe) || Pointer(Void).null) != 0
    end

    protected def error_bell : Nil
      C.gtk_widget_error_bell(self)
    end
  end
end
