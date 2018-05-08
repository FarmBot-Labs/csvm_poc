class App
  def current
    @current ||= self.new
  end

  def run!
    # Main run loops
    until STDIN.eof?
      # Check for inbound stuff, esp. signals.
      current_message = InputManager.current.shift
      if current_message
        message = Message.new(current_message)
        MessageHandler.current.execute(message)
      else
        HyperVisor.current.tick_next_process
      end
      # (possibly) act on signals
      # Act on other stuff
      # perform next round robin tick
    end
  end
end