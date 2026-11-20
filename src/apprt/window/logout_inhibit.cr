# src/apprt/window/logout_inhibit.cr
module Apprt
  class App
    # Keeps the session from ending while a surface asks before closing; 0
    # when not inhibited.
    @logout_cookie = 0_u32

    # The reason the session manager shows for the inhibition.
    private LOGOUT_REASON = "Some windows ask before closing"

    # Whether the application asks the desktop not to log out, because a
    # surface asks before closing (`Surface#confirm_close?`).
    #
    # The desktop decides what to do with the request.
    def logout_inhibited? : Bool
      @logout_cookie != 0
    end

    # Inhibits logging out while any surface asks before closing, and lifts
    # the inhibition once none does.
    protected def sync_logout_inhibit : Nil
      wanted = running? && @surfaces.each_value.any?(&.confirm_close?)
      if wanted && @logout_cookie == 0
        @logout_cookie = C.gtk_application_inhibit(@application, nil, C::GtkApplicationInhibitFlags::Logout, LOGOUT_REASON)
      elsif !wanted
        release_logout_inhibit
      end
    end

    private def release_logout_inhibit : Nil
      cookie = @logout_cookie
      return if cookie == 0
      @logout_cookie = 0_u32
      C.gtk_application_uninhibit(@application, cookie) unless @application.null?
    end
  end
end
