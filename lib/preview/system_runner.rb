require "open3"

module Preview
  class SystemRunner
    Result = PreviewManager::Result

    def run(*cmd, capture: false, timeout: nil)
      if capture
        out, err, status = Open3.capture3(*cmd)
        Result.new(ok: status.success?, stdout: out, stderr: err, exit_code: status.exitstatus)
      else
        ok = system(*cmd)
        Result.new(ok: ok, stdout: "", stderr: "", exit_code: $?.exitstatus)
      end
    end
  end
end
