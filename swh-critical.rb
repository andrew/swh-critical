#!/usr/bin/env ruby
require "bundler/setup"
require_relative "lib/cli"

$stdout.sync = true
Signal.trap("TERM") { raise Interrupt }
exit SwhCritical::CLI.run(ARGV)
