#  Copyright 2009 Max Howell and other contributors.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#
#  THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
#  IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
#  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
#  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
#  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
#  NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
#  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
#  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
#  THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
class AbstractDownloadStrategy
  def initialize url, name, version, specs
    @url=url
    case specs when Hash
      @spec = specs.keys.first # only use first spec
      @ref = specs.values.first
    end
    @unique_token="#{name}-#{version}" unless name.to_s.empty? or name == '__UNKNOWN__'
  end
end

class CurlDownloadStrategy <AbstractDownloadStrategy
  def fetch
    ohai "Downloading #{@url}"
    if @unique_token
      @dl=HOMEBREW_CACHE+(@unique_token+ext)
    else
      @dl=HOMEBREW_CACHE+File.basename(@url)
    end
    unless @dl.exist?
      begin
        curl @url, '-o', @dl
      rescue Exception
        @dl.unlink if @dl.exist?
        raise
      end
    else
      puts "File already downloaded and cached to #{HOMEBREW_CACHE}"
    end
    return @dl # thus performs checksum verification
  end
  def stage
    # magic numbers stolen from /usr/share/file/magic/
    File.open(@dl) do |f|
      # get the first four bytes
      case f.read(4)
      when /^PK\003\004/ # .zip archive
        safe_system '/usr/bin/unzip', '-qq', @dl
        chdir
      when /^\037\213/, /^BZh/ # gzip/bz2 compressed
        # TODO check if it's really a tar archive
        safe_system '/usr/bin/tar', 'xf', @dl
        chdir
      else
        # we are assuming it is not an archive, use original filename
        # this behaviour is due to ScriptFileFormula expectations
        # So I guess we should cp, but we mv, for this historic reason
        # HOWEVER if this breaks some expectation you had we *will* change the
        # behaviour, just open an issue at github
        FileUtils.mv @dl, File.basename(@url)
      end
    end
  end
private
  def chdir
    entries=Dir['*']
    case entries.length
      when 0 then raise "Empty archive"
      when 1 then Dir.chdir entries.first rescue nil
    end
  end
  def ext
    # GitHub uses odd URLs for zip files, so check for those
    rx=%r[http://(www\.)?github\.com/.*/(zip|tar)ball/]
    if rx.match @url
      if $2 == 'zip'
        '.zip'
      else
        '.tgz'
      end
    else
      Pathname.new(@url).extname
    end
  end
end

class HttpDownloadStrategy <CurlDownloadStrategy
  def initialize url, name, version, specs
    opoo "HttpDownloadStrategy is deprecated"
    puts "Please use CurlDownloadStrategy in future"
    puts "HttpDownloadStrategy will be removed in version 0.5"
    super url, name, version, specs
  end
end

class SubversionDownloadStrategy <AbstractDownloadStrategy
  def fetch
    ohai "Checking out #{@url}"
    @co=HOMEBREW_CACHE+@unique_token
    unless @co.exist?
      args = [svn, 'checkout', @url, @co]
      args << '-q' unless ARGV.verbose?
      safe_system *args
    else
      # TODO svn up?
      puts "Repository already checked out"
    end
  end
  def stage
    # Force the export, since the target directory will already exist
    args = [svn, 'export', '--force', @co, Dir.pwd]
    args << '-r' << @ref if @spec == :revision and @ref
    args << '-q' unless ARGV.verbose?
    safe_system *args
  end

  # currently only used by mplayer.rb
  def svn
    '/usr/bin/svn'
  end
end

class GitDownloadStrategy <AbstractDownloadStrategy
  def fetch
    ohai "Cloning #{@url}"
    @clone=HOMEBREW_CACHE+@unique_token
    unless @clone.exist?
      safe_system 'git', 'clone', @url, @clone
    else
      # TODO git pull?
      puts "Repository already cloned to #{@clone}"
    end
  end
  def stage
    dst = Dir.getwd
    Dir.chdir @clone do
      if @spec and @ref
        ohai "Checking out #{@spec} #{@ref}"
        case @spec
        when :branch
          nostdout { safe_system 'git', 'checkout', "origin/#{@ref}" }
        when :tag
          nostdout { safe_system 'git', 'checkout', @ref }
        end
      end
      # http://stackoverflow.com/questions/160608/how-to-do-a-git-export-like-svn-export
      safe_system 'git', 'checkout-index', '-af', "--prefix=#{dst}/"
    end
  end
end

class CVSDownloadStrategy <AbstractDownloadStrategy
  def fetch
    ohai "Checking out #{@url}"
    @co=HOMEBREW_CACHE+@unique_token

    # URL of cvs cvs://:pserver:anoncvs@www.gccxml.org:/cvsroot/GCC_XML:gccxml
    # will become:
    # cvs -d :pserver:anoncvs@www.gccxml.org:/cvsroot/GCC_XML login
    # cvs -d :pserver:anoncvs@www.gccxml.org:/cvsroot/GCC_XML co gccxml
    mod, url = split_url(@url)

    unless @co.exist?
      Dir.chdir HOMEBREW_CACHE do
        safe_system '/usr/bin/cvs', '-d', url, 'login'
        safe_system '/usr/bin/cvs', '-d', url, 'checkout', '-d', @unique_token, mod
      end
    else
      # TODO cvs up?
      puts "Repository already checked out"
    end
  end

  def stage
    FileUtils.cp_r(Dir[HOMEBREW_CACHE+@unique_token+"*"], Dir.pwd)

    require 'find'

    Find.find(Dir.pwd) do |path|
      if FileTest.directory?(path) && File.basename(path) == "CVS"
        Find.prune
        FileUtil.rm_r path, :force => true
      end
    end
  end

private
  def split_url(in_url)
    parts=in_url.sub(%r[^cvs://], '').split(/:/)
    mod=parts.pop
    url=parts.join(':')
    [ mod, url ]
  end
end

class MercurialDownloadStrategy <AbstractDownloadStrategy
  def fetch
    raise "You must install mercurial, there are two options:\n\n"+
          "    brew install pip && pip install mercurial\n"+
          "    easy_install mercurial\n\n"+
          "Homebrew recommends pip over the OS X provided easy_install." \
          unless system "/usr/bin/which hg"

    ohai "Cloning #{@url}"
    @clone=HOMEBREW_CACHE+@unique_token

    url=@url.sub(%r[^hg://], '')

    unless @clone.exist?
      safe_system 'hg', 'clone', url, @clone
    else
      # TODO hg pull?
      puts "Repository already cloned"
    end
  end
  def stage
    dst=Dir.getwd
    Dir.chdir @clone do
      if @spec and @ref
        ohai "Checking out #{@spec} #{@ref}"
        Dir.chdir @clone do
          safe_system 'hg', 'archive', '-y', '-r', @ref, '-t', 'files', dst
        end
      else
        safe_system 'hg', 'archive', '-y', '-t', 'files', dst
      end
    end
  end
end
