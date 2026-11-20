# src/desktop_kit/wayland/user_idle.cr
module DesktopKit
  abstract class App
    @idle_timeout : Time::Span?
    @idle_notification : Wayland::Proxy?

    # Returns how long the user may leave the keyboard and pointer alone
    # before `#on_user_idle` reports them idle, or `nil` when nothing is
    # reported.
    getter idle_timeout : Time::Span?

    # Returns whether the user is idle; see `#idle_timeout`.
    getter? user_idle = false

    # Sets how long the user may leave the keyboard and pointer alone
    # before `#on_user_idle` reports them idle; `nil` stops the reports.
    #
    # The desktop decides when the user is idle and may not tell at all;
    # while an application keeps the desktop awake (see
    # `Window#idle_inhibited=`) the user never turns idle.
    def idle_timeout=(timeout : Time::Span?) : Time::Span?
      @idle_timeout = timeout
      UIThread.dispatch { watch_user_idle } if running?
      timeout
    end

    # :showdoc:
    #
    # Called when the user turns *idle* once `#idle_timeout` passed without
    # input, and when they come back.
    protected def on_user_idle(idle : Bool) : Nil
    end

    private def watch_user_idle : Nil
      release_user_idle
      timeout = @idle_timeout || return
      display = C.gdk_display_get_default
      return if display.null?
      notifier = Wayland.globals(display).try(&.idle_notifier) || return
      seat = C.gdk_display_get_default_seat(display)
      return if seat.null? || C.g_type_check_instance_is_a(seat, C.gdk_wayland_seat_get_type) == 0
      # ext_idle_notifier_v1 v1 `get_idle_notification` honours idle
      # inhibitors (v2's `get_input_idle_notification` ignores them).
      milliseconds = timeout.total_milliseconds.clamp(0, UInt32::MAX).to_u32
      notification = notifier.create(Wayland::IDLE_NOTIFIER_GET, :idle_notification, Wayland::NEW_ID, milliseconds,
        C.gdk_wayland_seat_get_wl_seat(seat))
      notification.listen do |opcode, _args|
        case opcode
        when Wayland::IDLE_IDLED   then user_idle_changed(true)
        when Wayland::IDLE_RESUMED then user_idle_changed(false)
        end
      end
      @idle_notification = notification
    end

    private def user_idle_changed(idle : Bool) : Nil
      return if idle == @user_idle
      @user_idle = idle
      on_user_idle(idle)
    end

    private def release_user_idle : Nil
      @idle_notification.try(&.destroy(Wayland::IDLE_NOTIFICATION_DESTROY))
      @idle_notification = nil
      user_idle_changed(false)
    end
  end
end
