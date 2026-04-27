# When the Rails process is killed mid-preview, the docker container outlives
# the supervisor. On next boot we reconcile: kill stray preview-* containers
# and flip any :starting / :running rows to :stopped with an error marker so
# the user sees the divergence rather than a phantom "running" pill.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  # Only run during real server / runner / console boots — not migrations,
  # asset precompile, etc. (which load the env but don't serve previews).
  command = ARGV.first.to_s
  next unless %w[server runner console s c].include?(command) || ENV["BIN_DEV"] == "1"

  Preview::PreviewManager.reset_orphans!
end
