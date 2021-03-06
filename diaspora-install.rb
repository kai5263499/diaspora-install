#!/usr/bin/env ruby

# NOTE
# this is quite a big file, so get an editor that has decent code folding
# capabilities ... you don't have to view it all at once ;)

# NOTE
# there mustn't be any gem dependencies. only ruby stdlib should be require-d
require 'fileutils'
require 'open3'
require 'open-uri'

$stdout.sync = true

# ==  define some urls  ========================================================
DIASPORA = {
  repo_url: 'https://github.com/diaspora/diaspora.git',
  wiki_url: 'https://wiki.diasporafoundation.org/',
  irc_url:  'irc://freenode.net/diaspora',

  ruby_version_url: 'https://raw.githubusercontent.com/diaspora/diaspora/develop/.ruby-version',
  ruby_gemset_url: 'https://raw.githubusercontent.com/diaspora/diaspora/develop/.ruby-gemset',

  git_branch: 'develop',

  # populated by .ruby-version and .ruby-gemset
  #ruby_version: '2.0.0-p353',
  #rubygems_version: '2.1.11',
  #gemset: 'diaspora',

  rvm_local_path: "#{ENV['HOME']}/.rvm/scripts/rvm",
  rvm_system_path: '/usr/local/rvm/scripts/rvm'
}

# ==  required binaries  =======================================================
BINARIES = {
  bash: 'bash',
  git: 'git',
  ruby: 'ruby',  # duh!
  rubygems: 'gem',
  redis: 'redis-server',
  gcc: 'gcc'
}

# ==  global state  ============================================================
STATE = {
  rvm_found: false,
  rvm_source_local: false,
  rvm_source_system: false,
  js_runtime_found: false,
  log_level: 2,
  git_clone_path: '/srv/diaspora',
  allow_root: false,
  headless: false
}

# ==  define message strings  ==================================================
MESSAGES = {
  not_interactive: \
%Q{This script must be run interactively, it requires user input!},
  no_root: %Q{Don't run this script as root!},
  not_found: %Q{NOT FOUND},
  not_ok: %Q{NOT OK},
  found: %Q{FOUND},
  ok: %Q{OK},
  info_help: \
%Q{have a look at our wiki: #{DIASPORA[:wiki_url]}
or join us on IRC: #{DIASPORA[:irc_url]}},
  debugging: \
%Q{(you can also try to run this script with '-d' or '-v' switches for more information)},
  done_enter_continue: \
%Q{When you're done, come back here and press [Enter] to continue...},
  type_enter_continue: %Q{type something and/or just press [Enter] to continue...},
  enter_create_continue: %Q{Press [Enter] to create it and continue...},
  enter_continue: %Q{Press [Enter] to continue...},
  rvm_check: %Q{checking for rvm...},
  rvm_continue: \
%Q{Press [Enter] to continue without RVM or abort this script and install it...},
  rvm_not_found: \
%Q{RVM was not found on your system (or it isn't working properly).
It is higly recommended to use it, since it allows you to easily
install, update, manage and work with multiple ruby environments.

For more details check out https://rvm.io//},
  rvmrc_trusted: %Q{'.rvmrc' will be trusted from now on},
  ruby_version_check: %Q{checking Ruby version...},
  ruby_version_fatal: \
%Q{Make sure to install the right ruby version, before continuing with this script!},
  gemset_check: %Q{checking for RVM gemset...},
  gemset_fail: %Q{unable to find or create the RVM gemset...},
  rubygems_version_check: %Q{checking rubygems version...},
  rubygems_try_install: %Q{trying to install the required rubygems version...},
  rubygems_fail: \
%Q{The required rubygems version was not found and could not be installed!
You may try it with your existing version, but it might not work...},
  jsrt_check: %Q{checking for a JavaScript runtime...},
  jsrt_not_found: \
%Q{This script was unable to find a JavaScript runtime compatible to ExecJS on
your system. We recommend you install either Node.js or TheRubyRacer, since
those have been proven to work.

    Node.js      -- http://nodejs.org/
    TheRubyRacer -- https://github.com/cowboyd/therubyracer

For more information on ExecJS, visit
-- https://github.com/sstephenson/execjs},
  jsrt_fatal: %Q{Can't continue without a JS runtime!},
  bundler_check: %Q{checking for 'bundler' gem...},
  bundler_try_install: %Q{trying to install 'bundler' gem...},
  bundler_fatal: %Q{'bundler' gem was not found and could not be installed!},
  git_clone: \
%Q{Where would you like to put the git clone, or,
where is your existing git clone?},
  git_nonexistent_folder: \
%Q{The folder you specified does not exist.},
  git_no_repo: %Q{The specified folder doesn't contain a git repo},
  git_cloning: %Q{cloning the git repo...},
  db_cfg_created: %Q{created DB config file 'config/database.yml},
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
  db_skipped: %Q{loading the DB schema skipped by user},
  db_creating: \
%Q{creating the DB as specified in 'config/database.yml', please wait...},
  config_created: %Q{created diaspora* config file 'config/diaspora.yml'},
  config_msg: \
%Q{You're encouraged to look at the config file, that was just created,
in 'config/diaspora.yml', later. For development you won't have to change
anything for now. Still, it might be interesting ;)},
  installing_gems: %Q{installing all required gems...},
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
module Log
  # +30 is added to foreground colors and +40 for background colors for use
  # in the shell escape sequences
  COLORS = { black: 0, red: 1, green: 2, yellow: 3, blue: 4, magenta: 5, cyan: 6, light_gray: 7,
             dark_gray: 60, light_red: 61, light_green: 62, light_yellow: 63, light_blue: 64,
             light_magenta: 65, light_cyan: 66, white: 67 }
  COLOR_MAP = { verbose: :dark_gray, debug: :white, info: :cyan, warn: :yellow,
                error: :red, fatal: :red, unknown: :blue, cont: :white }
  DULL   = 0
  BRIGHT = 1
  ESC    = "\033"
  RESET  = "#{ESC}[0m"
  ONE_UP = "#{ESC}[1A"
  ERASE  = "#{ESC}[K"

  MAX_WIDTH = 70

  class << self
    [:info, :warn, :error, :unknown].each do |level|
      define_method level do |msg|
        fmt_msg(msg, level)
      end
    end

    [:verbose, :debug].each do |level|
      define_method level do |msg|
        if send("#{level.to_s}?")
          fmt_msg(msg, level)
        else
          reset_log_for_quiet_levels
          append(".")
        end
      end
    end

    # just output some text without a log level
    def text(msg="", nested=false)
      @last_msg = ""
      @last_lvl = nil

      msg = "\n#{msg}\n \n" unless nested

      if msg.include?("\n")
        msg.split("\n").each do |line|
          text(line, true)
        end
        return
      end

      message = colorize(msg, :white, :black, true)
      blocks  = colorize("  ", :black, :white)

      puts "#{blocks}   #{message}"
    end

    def fatal(msg="")
      fmt_msg(msg, :fatal)

      help = MESSAGES[:info_help]
      help += "\n\n#{MESSAGES[:debugging]}" if STATE[:log_level] > 1

      text(help)
      exit 1
    end

    # append to a prevous message
    def append(msg="")
      print "\r#{ONE_UP}#{ERASE}"
      fmt_msg("#{@last_msg} #{msg.to_s.strip}", @last_lvl)
    end

    def prompt(msg_id)
      enter_to_continue(msg_id, true)
    end

    def enter_to_continue(msg_id=:enter_continue, prompt=false)
      if STATE[:headless]
        return
      end

      Check.interactive?  # just to be sure...

      Log.info MESSAGES[msg_id] unless msg_id==""

      if prompt
        print colorize("  ", :black, :dark_gray) + " > "
      else
        print ONE_UP
      end

      $stdin.gets.strip
    end

    def verbose?
      (STATE[:log_level] < 1)
    end

    def debug?
      (STATE[:log_level] < 2)
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

    def reset_log_for_quiet_levels
      fmt_msg("", :info) unless [:info, :cont].include?(@last_lvl)
    end

    def fmt_msg(msg="", level=nil)
      @last_msg = msg.to_s.strip
      @last_lvl = level

      color = (level ? COLOR_MAP[level] : :white)
      blocks = colorize("  ", :black, color)

      lvl = "         "
      lvl = colorize("[#{level.to_s.center(7)}]", COLOR_MAP[level], :black, true) if level && level!=:cont

      prefix = "#{blocks} "
      prefix += "#{lvl} --" if level

      msg = colorize(msg, :white, :black, true) unless level

      max_w = level ? MAX_WIDTH : MAX_WIDTH+12

      if @last_msg.size <= max_w
        puts "#{prefix} #{msg.to_s.strip}"
      else
        msg_arr = @last_msg.gsub(/\n/m, "").scan(/.{1,#{max_w}}/).flatten
        fmt_msg(msg_arr.shift, @last_lvl)
        lvl = @last_lvl ? :cont : nil
        msg_arr.each { |msg| fmt_msg(msg, lvl) }
      end
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
      Log.verbose "running: #{command}"
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
        Log.verbose @status
      end

      return '' if mode.include?(:silent)
      out.strip
    end

    private

    def prefix(mode)
      # create an 'interactive' bash, to load bashrc files
      prfx = "bash -i -l -c '" if mode.include?(:interactive) || mode.include?(:rvm)
      if mode.include?(:rvm)
        rvm_cmd = "rvm use #{DIASPORA[:ruby_version]}@#{DIASPORA[:gemset]}" if STATE[:rvm_found]
        rvm_cmd = ". #{DIASPORA[:rvm_local_path]} && #{rvm_cmd}" if STATE[:rvm_source_local]
        rvm_cmd = ". #{DIASPORA[:rvm_system_path]} $$ #{rvm_cmd}" if STATE[:rvm_source_system]

        prfx = "#{prfx} #{rvm_cmd} && "
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
      if not STATE[:headless]
        $stdin.reopen(File.open("/dev/tty", "r")) unless $stdin.tty?
        Log.fatal MESSAGES[:not_interactive] unless $stdin.tty?  # still not interactive...
      else
        return false
      end
    end

    def root?
      `id -u`.strip == "0"
    end

    def binaries?
      BINARIES.each do |k,v|
        Log.info "checking for #{k}..."

        Bash.which v
        Log.fatal "you are missing the '#{v}' command, please install #{k}" unless Bash.status.exitstatus == 0
        Log.append MESSAGES[:found]
      end
    end

    def rvm?
      Log.info MESSAGES[:rvm_check]

      # does rvm load inside bash
      if (Bash.builtin('type -t rvm') == "function")
        STATE[:rvm_found] = true
      elsif (ENV.key?('HOME') && File.exists?(DIASPORA[:rvm_local_path]))
        STATE[:rvm_source_local] = STATE[:rvm_found] = true
      elsif File.exists?(DIASPORA[:rvm_system_path])
        STATE[:rvm_source_system] = STATE[:rvm_found] = true
      end

      if STATE[:rvm_found]
        Log.append MESSAGES[:found]
        return
      end

      Log.warn MESSAGES[:not_found]
      Log.text MESSAGES[:rvm_not_found]
      Log.enter_to_continue :rvm_continue
    end

    def ruby_version?
      return unless STATE[:rvm_found]

      Log.info MESSAGES[:ruby_version_check]

      Bash.function "rvm use #{DIASPORA[:ruby_version]}"
      if Bash.status.exitstatus == 0
        Log.append MESSAGES[:ok]
        return
      end

      Log.error MESSAGES[:not_ok]
      Log.text \
%Q{Unable to change ruby version to #{DIASPORA[:ruby_version]} using RVM.
Please install it with:

    \`rvm install #{DIASPORA[:ruby_version]}\`
}
      Log.fatal MESSAGES[:ruby_version_fatal]
    end

    def gemset?
      return unless STATE[:rvm_found]

      Log.info MESSAGES[:gemset_check]

      Bash.function "rvm use #{DIASPORA[:ruby_version]}@#{DIASPORA[:gemset]}"
      if Bash.status.exitstatus == 0
        Log.append MESSAGES[:ok]
        return
      end

      Log.warn MESSAGES[:not_ok]
      Log.info "gemset #{DIASPORA[:gemset]} doesn't exist, creating it..."
      Bash.function "rvm #{DIASPORA[:ruby_version]} do rvm gemset create #{DIASPORA[:gemset]}"
      if Bash.status.exitstatus == 0
        Log.append MESSAGES[:ok]
        return
      end

      Log.warn MESSAGES[:gemset_fail]
      Log.enter_to_continue
    end

    def rubygems_version?
      Log.info MESSAGES[:rubygems_version_check]

      version = Bash.run("gem --version", :rvm).split("\n").last
      if version == DIASPORA[:rubygems_version]
        Log.append MESSAGES[:ok]
        return
      end

      Log.warn MESSAGES[:not_ok]
      return unless STATE[:rvm_found]

      Log.info MESSAGES[:rubygems_try_install]
      Bash.run("rvm rubygems #{DIASPORA[:rubygems_version]}", :rvm)
      if Bash.status.exitstatus == 0
        Log.append MESSAGES[:ok]
        return
      end

      Log.error MESSAGES[:rubygems_fail]
      Log.enter_to_continue
    end

    def js_runtime?
      Log.info MESSAGES[:jsrt_check]

      if (Bash.which("node") && Bash.status.exitstatus == 0) ||
         (Bash.which("nodejs") && Bash.status.exitstatus == 0)  # debian 'wheezy-backports'
        STATE[:js_runtime_found] = true
      elsif (Bash.run('ruby -e "require \"v8\""', :silent) && Bash.status.exitstatus == 0)
        STATE[:js_runtime_found] = true
      end

      if STATE[:js_runtime_found]
        Log.append MESSAGES[:found]
        return
      end

      Log.error MESSAGES[:not_found]
      Log.text MESSAGES[:jsrt_not_found]
      Log.fatal MESSAGES[:jsrt_fatal]
    end

    def bundler?
      Log.info MESSAGES[:bundler_check]

      Bash.run("gem which bundler", :rvm)
      if Bash.status.exitstatus == 0
        Log.append MESSAGES[:found]
        return
      end

      Log.warn MESSAGES[:not_found]
      Log.info MESSAGES[:bundler_try_install]
      Bash.run("gem install bundler", :interactive)
      if Bash.status.exitstatus == 0
        Log.append MESSAGES[:ok]
        return
      end

      Log.fatal MESSAGES[:bundler_fatal]
    end

    def all
      Check.binaries?
      Check.rvm?
      Check.ruby_version?
      Check.gemset?
      #Check.rubygems_version?
      Check.js_runtime?
      Check.bundler?
    end
  end
end

module Install
  class << self
    def prepare
      # fetch variables from repo
      open(DIASPORA[:ruby_version_url]) do |f|
        DIASPORA[:ruby_version] = f.gets.strip
      end

      open(DIASPORA[:ruby_gemset_url]) do |f|
        DIASPORA[:gemset] = f.gets.strip
      end
    end

    def git_repo
      Log.text MESSAGES[:git_clone]
      path = Log.prompt("")
      git_path = File.expand_path(path)
      STATE[:git_clone_path] = git_path

      Log.debug(git_path) if Log.debug?

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
      Log.info MESSAGES[:db_cfg_created]

      Log.text MESSAGES[:db_chk]
      Log.enter_to_continue :done_enter_continue

      Log.text MESSAGES[:db_msg]
      Log.enter_to_continue
    end

    def config_setup
      FileUtils.cp "config/diaspora.yml.example", "config/diaspora.yml"
      Log.info MESSAGES[:config_created]

      Log.text MESSAGES[:config_msg]
      Log.enter_to_continue
    end

    def gem_bundle
      Log.info MESSAGES[:installing_gems]
      Bash.run_or_error("bundle install", :rvm)
    end

    def db_populate
      Log.text MESSAGES[:db_create]
      input = Log.prompt :type_enter_continue

      unless input.empty?
        Log.info MESSAGES[:db_skipped]
        return
      end

      Log.info MESSAGES[:db_creating]
      Bash.run_or_error("bundle exec rake db:schema:load_if_ruby --trace", :rvm)
    end

    private

    def trust_rvmrc(rvmrc_path)
      rvmrc = File.join(rvmrc_path, '.rvmrc')
      return unless STATE[:rvm_found] && File.exists?(rvmrc)

      Bash.function "rvm rvmrc warning ignore #{File.expand_path(rvmrc)}"
      Log.info MESSAGES[:rvmrc_trusted]
    end

    def git_create_path(git_path)
      Log.info MESSAGES[:git_nonexistent_folder]
      Log.text "create '#{git_path}'?"
      Log.enter_to_continue :enter_create_continue

      Log.info "creating '#{git_path}' and cloning the git repo..."
      FileUtils.mkdir_p git_path

      git_create_clone(git_path)
    end

    def git_clone_path(git_path)
      Log.text MESSAGES[:git_no_repo]
      Log.enter_to_continue :enter_create_continue

      Log.info MESSAGES[:git_cloning]
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
  STDOUT.sync = true
  require 'optparse'

  optparse = OptionParser.new do |opts|
    opts.banner = "Usage: #{File.basename($0, '.*')} [options]"

    opts.on('-d', '--debug',
            'produce some extended debugging output') do
      STATE[:log_level] = 1
    end

    opts.on('-v', '--verbose',
            'produce a huge amount of mostly unnecessary output') do
      STATE[:log_level] = 0
    end

    opts.on('-h', '--help',
            'display this help') do
      puts opts
      exit
    end

    opts.on('-r', '--allowroot',
            'Allow install from root account') do
      STATE[:allowroot] = true
    end

    opts.on('-y', '--headless',
            'Allow unattended install') do
      STATE[:headless] = true
    end
  end

  optparse.parse!

  if STATE[:allowroot] == 0
    Log.fatal MESSAGES[:no_root] if Check.root? 
  end

  Log.text MESSAGES[:welcome]
  Log.enter_to_continue

  Install.prepare
  Check.all

  # we're still going, start installation

  Install.git_repo
  Install.db_setup
  Install.config_setup
  Install.gem_bundle
  Install.db_populate

  Log.text MESSAGES[:bye]
end
