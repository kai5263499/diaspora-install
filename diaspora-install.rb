#!/usr/bin/env ruby

# NOTE
# this is quite a big file, so get an editor that has decent code folding
# capabilities ... you don't have to view it all at once ;)

# NOTE
# there mustn't be any gem dependencies. only ruby stdlib should be require-d
require 'fileutils'
require 'open3'

$stdout.sync = true

# ==  define some urls  ========================================================
DIASPORA = {
  repo_url: 'https://github.com/diaspora/diaspora.git',
  wiki_url: 'https://wiki.diasporafoundation.org/',
  irc_url:  'irc://freenode.net/diaspora',

  git_branch: 'develop',
  ruby_version: '2.0.0-p353',

  rvm_local_path: "#{ENV['HOME']}/.rvm/scripts/rvm",
  rvm_system_path: '/usr/local/rvm/scripts/rvm'
}

# ==  required binaries  =======================================================
BINARIES = {
  bash: 'bash',
  git: 'git',
  ruby: 'ruby',  # duh!
  rubygems: 'gem',
  redis: 'redis-server'
}

# ==  global state  ============================================================
STATE = {
  rvm_found: false,
  rvm_source_local: false,
  rvm_source_system: false,
  js_runtime_found: false,
  git_clone_path: '/srv/diaspora'
}

# ==  define message strings  ==================================================
MESSAGES = {
  not_interactive: \
%Q{This script must be run interactively, it requires user input!},
  no_root: %Q{Don't run this script as root!},
  look_wiki: %Q{have a look at our wiki: #{DIASPORA[:wiki_url]}},
  join_irc: %Q{or join us on IRC: #{DIASPORA[:irc_url]}},
  rvm_continue: \
%Q{Press [Enter] to continue without RVM or abort this script and install it...},
  rvm_not_found: \
%Q{RVM was not found on your system (or it isn't working properly).
It is higly recommended to use it, since it allows you to easily
install, update, manage and work with multiple ruby environments.

For more details check out https://rvm.io//},
  ruby_version_mismatch: \
%Q{Unable to change ruby version to #{DIASPORA[:ruby_version]} using RVM.
Please install it with:

    \`rvm install #{DIASPORA[:ruby_version]}\`
},
  ruby_version_fatal: \
%Q{Make sure to install the right ruby version, before continuing with this script!},
  jsrt_not_found: \
%Q{This script was unable to find a JavaScript runtime compatible to ExecJS on
your system. We recommend you install either Node.js or TheRubyRacer, since
those have been proven to work.

    Node.js      -- http://nodejs.org/
    TheRubyRacer -- https://github.com/cowboyd/therubyracer

For more information on ExecJS, visit
-- https://github.com/sstephenson/execjs},
  jsrt_fatal: %Q{Can't continue without a JS runtime!},
  bundler_try_install: %Q{trying to install bundler...},
  bundler_fatal: %Q{'bundler' gem was not found and could not be installed!},
  git_clone: \
%Q{Where would you like to put the git clone, or,
where is your existing git clone?},
  git_nonexistent_folder: \
%Q{The folder you specified does not exist.},
  db_chk: \
%Q{You can now open the database config file in 'config/database.yml'
with your favorite editor and change the values to your needs.},
  db_msg: \
%Q{Please also make sure the database server is started and the credentials you
specified in the config file are working.
This script will try to populate the database in a later step.},
  db_create: \
%Q{It's time to populate the database with the table schema.
Type [N/n]+[Enter] to skip over any DB operations, or
simply press [Enter] to proceed with populating the DB.},
  config_msg: \
%Q{You're encouraged to look at the config file, that was just created,
in 'config/diaspora.yml', later. For development you won't have to change
anything for now. Still, it might be interesting ;)},
  welcome: \
%Q{#####################################################################

#{"DIASPORA* INSTALL SCRIPT".center(70)}

#{"----".center(70)}

 This script will guide you through the basic steps
 to get a DEVELOPMENT setup of diaspora* up and running

 For a PRODUCTION installation, please do *not* use this script!
 Follow the guide in our wiki, instead:

    -- #{DIASPORA[:wiki_url]}Installation_guides

#####################################################################},
  bye: \
%Q{#####################################################################

It worked! :)

Now, you should have a look at

  - config/database.yml      and
  - config/diaspora.yml

and change them to your liking. Then you should be able to
start Diaspora* in development mode with:

    \`rails s\`


For further information read the wiki at #{DIASPORA[:wiki_url]}
or join us on IRC #{DIASPORA[:irc_url]}}
}


# ==  logging helper  ==========================================================
class Log
  COLORS = { black: 0, red: 1, green: 2, yellow: 3, blue: 4, magenta: 5, cyan: 6, white: 7 }
  COLOR_MAP = { debug: :white, info: :cyan, warn: :yellow, error: :red, fatal: :red, unknown: :blue }
  DULL   = 0
  BRIGHT = 1
  ESC    = "\033"
  RESET  = "#{ESC}[0m"
  ONE_UP = "#{ESC}[1A"
  ERASE  = "#{ESC}[K"

  class << self
    [:debug, :info, :warn, :error, :unknown].each do |level|
      define_method level do |msg|
        fmt_msg(msg, level)
      end
    end

    def text(msg="", nested=false)
      msg = "\n#{msg}\n \n" unless nested

      if msg.include?("\n")
        msg.split("\n").each do |line|
          text(line, true)
        end
        return
      end

      message = colorize(msg, :white, :black, true)
      blocks  = colorize("  ", :black, :white)

      puts "#{blocks}  #{message}"
    end

    def out(msg="")
      if msg.include?("\n")
        msg.split("\n").each do |line|
          fmt_msg(line)
        end
        return
      end

      fmt_msg(msg)
    end

    def fatal(msg="")
      fmt_msg(msg, :fatal)
      fmt_msg(MESSAGES[:look_wiki])
      fmt_msg(MESSAGES[:join_irc])
      exit 1
    end

    # append to a prevous message
    def finish(msg="")
      print "\r#{ONE_UP}#{ERASE}"
      fmt_msg("#{@last_msg} #{msg}", @last_lvl)
    end

    def enter_to_continue
      Check.interactive?  # just to be sure...

      print ONE_UP
      $stdin.gets.strip
    end

    private

    def colorize?
      $stdout.tty?
    end

    def colorize(msg="", fg=:white, bg=:black, strong=false)
      return msg if !colorize?
      txt_col = "#{ESC}[#{strong ? BRIGHT : DULL };#{COLORS[fg]+30};#{COLORS[bg]+40}m"
      "#{RESET}#{txt_col}#{msg}#{RESET}"
    end

    def fmt_msg(msg="", level=nil)
      @last_msg = msg
      @last_lvl = level

      color = (level ? COLOR_MAP[level] : :white)
      blocks = colorize("  ", :black, color)

      lvl = "         "
      lvl = colorize("[#{level.to_s.center(7)}]", COLOR_MAP[level], :black, true) if level

      msg = colorize(msg, :white, :black, true) unless level

      puts "#{blocks} #{lvl} -- #{msg}"
    end
  end
end

module Bash
  class << self
    attr_reader :status

    def which(cmd)
      run "which #{cmd}", :silent
    end

    def builtin(cmd)
      run cmd, :interactive
    end
    alias_method :function, :builtin

    def run_or_error(cmd, *mode)
      output = run(cmd, *mode)
      Log.fatal "executing '#{cmd}' failed!" if @status.exitstatus != 0
      output
    end

    def run(cmd, *mode)
      command = "#{prefix(mode)}#{cmd}#{suffix(mode)}"
      Log.debug "running: #{command}"
      out = ''

      #`#{command}`.strip
      Open3.popen3(command) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        while !stdout.eof?
          tmp = stdout.gets
          Log.debug tmp
          out += tmp
        end
        stdout.close

        while !stderr.eof?
          Log.warn stderr.gets
        end
        stderr.close

        @status = wait_thr.value
        Log.debug @status
      end

      return '' if mode.include?(:silent)
      out.strip
    end

    private

    def prefix(mode)
      # create an 'interactive' bash, to load bashrc files
      prfx = "bash -i -c '" if mode.include?(:interactive) || mode.include?(:rvm)
      if mode.include?(:rvm)
        rvm_path = (STATE[:rvm_source_local] ? DIASPORA[:rvm_local_path] : DIASPORA[:rvm_system_path])
        prfx = "#{prfx} . #{rvm_path} && "
      end
      prfx
    end

    def suffix(mode)
      sfx = "' #{sfx}" if mode.include?(:interactive) || mode.include?(:rvm)
      sfx
    end
  end
end

module Check
  class << self
    def interactive?
      # try to reopen tty. see: http://stackoverflow.com/a/6840338
      $stdin.reopen(File.open("/dev/tty", "r")) unless $stdin.tty?
      Log.fatal MESSAGES[:not_interactive] unless $stdin.tty?  # still not interactive...
    end

    def root?
      `id -u`.strip == "0"
    end

    def binaries?
      BINARIES.each do |k,v|
        Log.info "checking for #{k}..."

        Bash.which v
        Log.fatal "you are missing the #{v} command, please install #{k}" unless Bash.status.exitstatus == 0
        Log.finish "found"
      end
    end

    def rvm?
      Log.info "checking for rvm..."

      # does rvm load inside bash
      if (Bash.builtin('type -t rvm') == "function")
        STATE[:rvm_found] = true
      end

      if (ENV.key?('HOME') && File.exists?(DIASPORA[:rvm_local_path]))
        STATE[:rvm_source_local] = true
      elsif File.exists?(DIASPORA[:rvm_system_path])
        STATE[:rvm_source_system] = true
      end

      if STATE[:rvm_found]
        Log.finish "found"
        return
      end

      Log.warn "not found"
      Log.out MESSAGES[:rvm_not_found]
      Log.info MESSAGES[:rvm_continue]
      Log.enter_to_continue
    end

    def ruby_version?
      return unless STATE[:rvm_found]

      Log.info "checking ruby version..."

      Bash.function "rvm use #{DIASPORA[:ruby_version]}"
      if Bash.status.exitstatus == 0
        Log.finish "ok"
        return
      end

      Log.error "not ok"
      Log.out MESSAGES[:ruby_version_mismatch]
      Log.fatal MESSAGES[:ruby_version_fatal]
    end

    def js_runtime?
      Log.info "checking for a JavaScript runtime..."

      if (Bash.which("node") && Bash.status.exitstatus == 0)
        STATE[:js_runtime_found] = true
      elsif (Bash.run('ruby -e "require \"v8\""', :silent) && Bash.status.exitstatus == 0)
        STATE[:js_runtime_found] = true
      end

      if STATE[:js_runtime_found]
        Log.finish "found"
        return
      end

      Log.error "not found"
      Log.out MESSAGES[:jsrt_not_found]
      Log.fatal MESSAGES[:jsrt_fatal]
    end

    def bundler?
      Log.info "checking for 'bundler' gem..."

      Bash.run("gem which bundler", :interactive, :silent)
      if Bash.status.exitstatus == 0
        Log.finish "found"
        return
      end

      Log.warn "not ok"
      Log.info MESSAGES[:bundler_try_install]
      Bash.run("gem install bundler", :interactive)
      if Bash.status.exitstatus == 0
        Log.info "ok"
        return
      end

      Log.fatal MESSAGES[:bundler_fatal]
    end

    def all
      Check.binaries?
      Check.rvm?
      Check.ruby_version?
      Check.js_runtime?
      Check.bundler?
    end
  end
end

class Install
  class << self
    def git_repo
      Log.text MESSAGES[:git_clone]
      git_path = File.expand_path(gets).strip
      STATE[:git_clone_path] = git_path

      Log.debug(git_path)

      if !Dir.exists?(git_path)
        git_create_path(git_path)
      elsif !(Bash.run("cd #{git_path} && git status", :silent) && Bash.status.exitstatus == 0)
        git_clone_path(git_path)
      else
        git_checkout_branch(git_path)
      end

      Dir.chdir git_path
    end

    def db_setup
      FileUtils.cp "config/database.yml.example", "config/database.yml"
      Log.info "created DB config file 'config/database.yml"

      Log.text MESSAGES[:db_chk]
      Log.info "When you're done, come back here and press [Enter] to continue..."
      Log.enter_to_continue

      Log.text MESSAGES[:db_msg]
      Log.info "Press [Enter] to continue..."
      Log.enter_to_continue
    end

    def config_setup
      FileUtils.cp "config/diaspora.yml.example", "config/diaspora.yml"
      Log.info "created diaspora* config file 'config/diaspora.yml'"

      Log.text MESSAGES[:config_msg]
      Log.info "Press [Enter] to continue..."
      Log.enter_to_continue
    end

    def gem_bundle
      Log.info "installing all required gems..."
      Bash.run_or_error("bundle install", :rvm)
    end

    def db_populate
      Log.text MESSAGES[:db_create]
      Log.info "type something and/or just press [Enter] to continue..."
      input = Log.enter_to_continue

      unless input.empty?
        Log.info "loading the DB schema skipped by user"
        return
      end

      Log.info "creating the DB as specified in 'config/database.yml', please wait..."
      Bash.run_or_error("bundle exec rake db:schema:load_if_ruby --trace", :rvm)
    end

    private

    def trust_rvmrc(rvmrc_path)
      rvmrc = File.join(rvmrc_path, '.rvmrc')
      return unless STATE[:rvm_found] && File.exists?(rvmrc)

      Bash.function "rvm rvmrc warning ignore #{File.expand_path(rvmrc)}"
      Log.info "'.rvmrc' will be trusted from now on"
    end

    def git_create_path(git_path)
      Log.info MESSAGES[:git_nonexistent_folder]
      Log.text "create '#{git_path}'?"
      Log.info "Press [Enter] to create it and continue..."
      Log.enter_to_continue

      Log.info "creating '#{git_path}' and cloning the git repo..."
      FileUtils.mkdir_p git_path

      git_create_clone(git_path)
    end

    def git_clone_path(git_path)
      Log.text "The specified folder doesn't contain a git repo"
      Log.info "Press [Enter] to create it and continue..."
      Log.enter_to_continue

      Log.info "cloning the git repo..."
      git_create_clone(git_path)
    end

    def git_checkout_branch(git_path)
      trust_rvmrc(git_path)

      Dir.chdir(git_path)
      Log.info "setting your git clone to '#{DIASPORA[:git_branch]}' branch.."

      Bash.run_or_error("git stash", :silent)
      Bash.run_or_error("git checkout #{DIASPORA[:git_branch]}", :silent)
      Bash.run_or_error("git pull", :silent)
    end

    def git_create_clone(git_path)
      Bash.run_or_error "git clone #{DIASPORA[:repo_url]} -b #{DIASPORA[:git_branch]} #{git_path}"
      trust_rvmrc(git_path)
    end
  end
end

# run this if the script is invoked directly
if __FILE__==$0
  Log.fatal MESSAGES[:no_root] if Check.root?
  Check.interactive?

  Log.text MESSAGES[:welcome]
  Log.info "Press [Enter] to continue..."
  Log.enter_to_continue

  Check.all

  # we're still going, start installation

  Install.git_repo
  Install.db_setup
  Install.config_setup
  Install.gem_bundle
  Install.db_populate

  Log.text MESSAGES[:bye]
end