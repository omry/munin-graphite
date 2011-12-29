#!/usr/bin/env ruby
#
# munin-graphite.rb
# 
# A Munin-Node to Graphite bridge
#
# Author:: Adam Jacob (<adam@hjksolutions.com>)
# Author:: Omry Yadan (<omry@yadan.net>)
# Copyright:: Copyright (c) 2008 HJK Solutions, LLC
# License:: GNU General Public License version 2 or later
# 
# This program and entire repository is free software; you can
# redistribute it and/or modify it under the terms of the GNU 
# General Public License as published by the Free Software 
# Foundation; either version 2 of the License, or any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
# 

require 'socket'
require 'syslog'
require 'optparse'

$options = {}
optparse = OptionParser.new do|opts|
	# Set a banner, displayed at the top
	# of the help screen.
	opts.banner = "Munin to Graphite bridge"

	$options[:verbose] = false
	opts.on( '-v', '--verbose', 'Output more information' ) do
		$options[:verbose] = true
	end

	opts.on( '-h', '--help', 'Display this screen' ) do
		puts opts
		exit
	end
end

optparse.parse!

class Munin
	def initialize(host='localhost', port=4949)
		@munin = TCPSocket.new(host, port)
		@munin.gets
	end

	def get_response(cmd)
		@munin.puts(cmd)
		stop = false 
		response = Array.new
		while stop == false
			line = @munin.gets
			line.chomp!
			if line == '.'
				stop = true
			else
				response << line 
				stop = true if cmd == "list"
			end
		end
		response
	end

	def close
		@munin.close
	end
end

class Carbon
	def initialize(host='localhost', port=2003)
		@carbon = TCPSocket.new(host, port)
	end

	def send(msg)
		@carbon.puts(msg)
	end

	def close
		@carbon.close
	end
end

def error(msg)
	puts "error : #{msg}"
	Syslog.open($0, Syslog::LOG_PID | Syslog::LOG_CONS) { |s| s.err msg }
end

def warn(msg)
	puts "warn : #{msg}"
	Syslog.open($0, Syslog::LOG_PID | Syslog::LOG_CONS) { |s| s.warning msg }
end

def info(msg)
	puts "info : #{msg}"
	Syslog.open($0, Syslog::LOG_PID | Syslog::LOG_CONS) { |s| s.info msg }
end

def sleep1(interval, elapsed)
	if (elapsed >= interval)
		warn("Fetching munin data took #{elapsed} > interval = #{interval} ms")
	else
		s = interval - elapsed
		if ($options[:verbose])
			info("Sleeping #{s} seconds")
		end
		sleep s
	end
end

munin_host = "localhost"
munin_port = 4949
carbon_host = ARGV[0]
if !carbon_host
	info("Carbon host not specified, using localhost")
	carbon_host = "localhost"
end
carbon_port = 2003
interval = 5*60
info("Forwarding stats from munin #{munin_host}:#{munin_port} to carbon #{carbon_host}:#{carbon_port} every #{interval} seconds")

munin_error = false
carbon_error = false
while true
	fetch_start = Time.now.to_f
	metric_base = "servers."
	all_metrics = Array.new

	begin
		munin = Munin.new(munin_host, munin_port)
		if munin_error
			info("Connection to munin re-established")
			munin_error = false
		end
		mname = "unknown"
		munin.get_response("nodes").each do |node|
			metric_base << node.split(".").reverse.join(".")
			#puts "Doing #{metric_base}"
			munin.get_response("list")[0].split(" ").each do |metric|
				metric = metric.gsub(' ','_')
				#puts "Grabbing #{metric}"
				mname = "#{metric_base}"
				has_category = false
				base = false
				munin.get_response("config #{metric}").each do |configline|
					if configline =~ /graph_category (.+)/
						mname << ".#{$1}".gsub(' ','_')
						has_category = true
					end
					if configline =~ /graph_args.+--base (\d+)/
						base = $1
					end
				end
				mname << ".other" unless has_category
				t = Time.now.to_f
				munin.get_response("fetch #{metric}").each do |line|
					line =~ /^(.+)\.value\s+(.+)$/
					field = $1
					value = $2
					field = field.gsub(' ','_')
					all_metrics << "#{mname}.#{metric}.#{field} #{value} #{Time.now.to_i}"
				end

				if ($options[:verbose])
					info("Fetching #{metric} took #{(Time.now.to_f - t)} seconds")
				end
			end
		end
	rescue => e
		if !munin_error
			error("Error communicating with munin: #{e.message}")
			munin_error = true
		end
		fetch_end = Time.now.to_i
		elapsed = fetch_end - fetch_start
		sleep1(interval,elapsed)
		next
	ensure
		munin.close
	end

	fetch_end = Time.now.to_i
	elapsed = fetch_end - fetch_start
	info("Sending munin stats to #{carbon_host}:#{carbon_port}, fetch took #{elapsed}")

	all_metrics << "#{mname}.munin_fetch_time #{elapsed} #{Time.now.to_i}"
	begin
		carbon = Carbon.new(carbon_host,carbon_port)
		if carbon_error
			info("Connection to carbon re-established")
			carbon_error = false
		end
		all_metrics.each do |m|
			if ($options[:verbose])
				puts "Sending #{m}"
			end
			carbon.send(m)
		end
	rescue => e
		if !carbon_error
			error("Error communicating with carbon : #{e.message}")
			carbon_error = true
		end
	ensure
		if (carbon)
			carbon.close
		end
	end
	sleep1(interval, elapsed)

end

