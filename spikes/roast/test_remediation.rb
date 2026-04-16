# typed: true
# frozen_string_literal: true

#: self as Roast::Workflow

# Test remediation loop pattern:
# 1. "Generate" something (simulated)
# 2. Verify — fail first 2 times, pass on 3rd
# 3. Remediation loop with repeat + break!
#
# Uruchomienie: bundle exec roast test_remediation.rb

config do
  cmd { display! }
end

# Scope: fix + re-verify
execute(:fix_and_verify) do
  ruby(:fix) do |_, errors, idx|
    puts "  [fix attempt #{idx}] Fixing errors: #{errors}"
    # Simulate fixing by writing a file
    File.write("/tmp/roast_test_counter", idx.to_s)
    "fixed"
  end

  ruby(:verify) do |_, _, idx|
    counter = File.read("/tmp/roast_test_counter").to_i rescue 0
    if counter < 2
      puts "  [verify #{idx}] FAIL — counter=#{counter}, need >= 2"
      fail!("verification failed: counter=#{counter}")
    else
      puts "  [verify #{idx}] PASS"
      "passed"
    end
  end

  # Break if verify passed, otherwise continue loop
  ruby do |_, _, idx|
    break! if ruby?(:verify)      # verify succeeded
    break! if idx >= 2             # max retries reached
    # otherwise: next iteration
  end

  outputs do
    ruby?(:verify) ? "remediation succeeded" : "remediation failed after max retries"
  end
end

# Main
execute do
  # Step 1: "generate" something
  ruby(:generate) do
    File.write("/tmp/roast_test_counter", "0")
    puts "[generate] Created initial code (simulated)"
    "generated"
  end

  # Step 2: first verify
  ruby(:initial_verify) do
    counter = File.read("/tmp/roast_test_counter").to_i rescue 0
    if counter < 2
      puts "[initial_verify] FAIL — need remediation"
      nil  # failed
    else
      puts "[initial_verify] PASS"
      "passed"
    end
  end

  # Step 3: remediation loop (skip if initial verify passed)
  repeat(:remediate, run: :fix_and_verify) do
    skip! if ruby!(:initial_verify).value == "passed"
    "initial verification errors"
  end

  # Step 4: report
  ruby(:report) do
    if ruby!(:initial_verify).value == "passed"
      puts "[report] Initial verification passed, no remediation needed"
    else
      result = repeat!(:remediate).value
      puts "[report] Remediation result: #{result}"
    end
  end
end
