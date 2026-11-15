# src/apprt/desktop/notifications.cr
module Apprt
  # :nodoc:
  # The desktop notifications one surface sent, kept so they can be
  # withdrawn. Notifications are keyed by the hash of their title and body:
  # sending the same one again replaces it and makes it the newest. At most
  # `LIMIT` are kept; sending more withdraws the oldest. One sent while the
  # surface is focused is withdrawn after `#timeout`. `#clear` withdraws all
  # of them, on focus gain and on close. A null *application* sends and
  # withdraws nothing, for the specs.
  class Notifications
    LIMIT           = 64
    FOCUSED_TIMEOUT = 3.seconds

    private class Entry
      getter key : UInt64
      property timeout : UInt32?

      def initialize(@key : UInt64)
      end
    end

    property timeout : Time::Span = FOCUSED_TIMEOUT
    @entries = [] of Entry

    def initialize(@application : Void*, @surface_id : UInt64, @limit : Int32 = LIMIT)
    end

    # The keys of the kept notifications, oldest first.
    def keys : Array(UInt64)
      @entries.map(&.key)
    end

    def send(title : String, body : String, focused : Bool) : Nil
      key = {title, body}.hash
      track(key)
      Notifications.deliver(@application, id(key), title, body, @surface_id)
      @entries.last.timeout = Idle.after(@timeout) { expire(key) } if focused
    end

    # Keeps *key* as the newest notification, withdrawing the oldest one when
    # the limit is reached.
    def track(key : UInt64) : Nil
      if index = @entries.index { |entry| entry.key == key }
        entry = @entries.delete_at(index)
        entry.timeout.try { |source| Idle.cancel(source) }
        entry.timeout = nil
        @entries << entry
        return
      end
      while @entries.size >= @limit
        oldest = @entries.shift
        oldest.timeout.try { |source| Idle.cancel(source) }
        withdraw(oldest.key)
      end
      @entries << Entry.new(key)
    end

    def clear : Nil
      @entries.each do |entry|
        entry.timeout.try { |source| Idle.cancel(source) }
        withdraw(entry.key)
      end
      @entries.clear
    end

    # Sends the notification *id*; clicking it activates
    # `app.present-surface` with *surface_id*.
    def self.deliver(application : Void*, id : String, title : String, body : String, surface_id : UInt64) : Nil
      return if application.null?
      notification = C.g_notification_new(title.presence || Window.default_title)
      C.g_notification_set_body(notification, body) unless body.empty?
      if app_id = Native.string?(C.g_application_get_application_id(application))
        icon = C.g_themed_icon_new(app_id)
        C.g_notification_set_icon(notification, icon)
        C.g_object_unref(icon)
      end
      C.g_notification_set_default_action_and_target_value(notification, "app.present-surface", C.g_variant_new_uint64(surface_id))
      C.g_application_send_notification(application, id, notification)
      C.g_object_unref(notification)
    end

    # The timer of *key* ran out; its source is gone already.
    private def expire(key : UInt64) : Nil
      index = @entries.index { |entry| entry.key == key } || return
      @entries.delete_at(index)
      withdraw(key)
    end

    private def withdraw(key : UInt64) : Nil
      C.g_application_withdraw_notification(@application, id(key)) unless @application.null?
    end

    private def id(key : UInt64) : String
      "apprt-surface-#{@surface_id.to_s(16)}-#{key.to_s(16)}"
    end
  end

  abstract class App
    # Shows a desktop notification from the application. Sending the same
    # *title* and *body* again replaces it. Use it on the GTK thread only.
    def notify(title : String, body : String) : Nil
      UIThread.assert!
      Notifications.deliver(@application, "apprt-#{{title, body}.hash.to_s(16)}", title, body, 0_u64)
    end

    protected def perform(target : App, action : Action::DesktopNotification) : Bool
      notify(action.title, action.body)
      true
    end

    protected def perform(target : App, action : Action::PresentSurface) : Bool
      surface(action.surface_id).try(&.present)
      true
    end
  end
end
