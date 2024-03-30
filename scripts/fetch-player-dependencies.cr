require "http"
require "yaml"
require "digest/sha1"
require "option_parser"
require "colorize"

# Taken from https://crystal-lang.org/api/1.1.1/OptionParser.html
minified = false
OptionParser.parse do |parser|
  parser.banner = "Usage: Fetch VideoJS dependencies [arguments]"
  parser.on("-m", "--minified", "Use minified versions of VideoJS dependencies (performance and bandwidth benefit)") { minified = true }

  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end

  parser.invalid_option do |flag|
    STDERR.puts "ERROR: #{flag} is not a valid option."
    STDERR.puts parser
    exit(1)
  end
end

required_dependencies = File.open("videojs-dependencies.yml") do |file|
  YAML.parse(file).as_h
end

def update_versions_yaml(required_dependencies, minified, dep_name)
  File.open("assets/videojs/#{dep_name}/versions.yml", "w") do |io|
    YAML.build(io) do |builder|
      builder.mapping do
        # Versions
        builder.scalar "version"
        builder.scalar "#{required_dependencies[dep_name]["version"]}"

        builder.scalar "minified"
        builder.scalar minified
      end
    end
  end
end

# https://github.com/crystal-lang/crystal/issues/2721
# https://github.com/j8r/crystal/commit/c613bbdc55b42418d4a70f9161a510b3025714be
def http_get_following_redirects(url, &)
  done = false
  while !done
    HTTP::Client.get(url) do |response|
      case response.status_code
      when 300, 301, 302, 303, 307, 308
        url = response.headers["Location"]
      else
        yield response
        done = true
      end
    end
  end
end

# The first step is to check which dependencies we'll need to install.
# If the version we have requested in `videojs-dependencies.yml` is the
# same as what we've installed, we shouldn't do anything. Likewise, if it's
# different or the requested dependency just isn't present, then it needs to be
# installed.

# Since we can't know when videojs-youtube-annotations is updated, we'll just always fetch
# a new copy each time.
dependencies_to_install = [] of String

required_dependencies.keys.each do |dep|
  dep = dep.to_s
  path = "assets/videojs/#{dep}"
  # Check for missing dependencies
  if !Dir.exists?(path)
    Dir.mkdir(path)
    dependencies_to_install << dep
  else
    config = File.open("#{path}/versions.yml") do |file|
      YAML.parse(file).as_h
    end

    if config["version"].as_s != required_dependencies[dep]["version"].as_s || config["minified"].as_bool != minified
      `rm -rf #{path}/*.js #{path}/*.css`
      dependencies_to_install << dep
    end
  end
end

# Now we begin the fun part of installing the dependencies.
# But first we'll setup a temp directory to store the plugins
tmp_dir_path = "#{Dir.tempdir}/invidious-videojs-dep-install"
Dir.mkdir(tmp_dir_path) if !Dir.exists? tmp_dir_path

channel = Channel(String | Exception).new

dependencies_to_install.each do |dep|
  spawn do
    dep_name = dep
    download_path = "#{tmp_dir_path}/#{dep}"
    dest_path = "assets/videojs/#{dep}"

    url = "https://registry.npmjs.org/#{dep}/-/#{dep}-#{required_dependencies[dep]["version"]}.tgz"
    if required_dependencies[dep]["github"]?
      url = "https://github.com/#{required_dependencies[dep]["github"]}/archive/#{required_dependencies[dep]["version"]}.tar.gz"
    end

    http_get_following_redirects(url) do |response|
      Dir.mkdir(download_path) if !Dir.exists? download_path
      data = response.body_io.gets_to_end
      File.write("#{download_path}/package.tgz", data)

      # https://github.com/iv-org/invidious/pull/2397#issuecomment-922375908
      sum_want = required_dependencies[dep]["shasum"]
      sum_got = `sha1sum #{download_path}/package.tgz`.split(" ")[0]
      if sum_want != sum_got
        raise Exception.new("Checksum for '#{dep}' failed (want #{sum_want}, got #{sum_got})")
      end
    end

    # Unless we install an external dependency, crystal provides no way of extracting a tarball.
    # Thus we'll go ahead and call a system command.
    `tar -vzxf '#{download_path}/package.tgz' -C '#{download_path}' --strip-components=1`
    raise "Extraction for #{dep} failed" if !$?.success?

    # Would use File.rename in the following steps but for some reason it just doesn't work here.
    # Video.js itself is structured slightly differently
    dep = "video" if dep == "video.js"

    # Would use File.rename but for some reason it just doesn't work here.
    if minified && File.exists?("#{download_path}/dist/#{dep}.min.js")
      `mv #{download_path}/dist/#{dep}.min.js #{dest_path}/#{dep}.js`
    else
      `mv #{download_path}/dist/#{dep}.js #{dest_path}/#{dep}.js`
    end

    # Fetch CSS which isn't guaranteed to exist
    #
    # Also, video JS changes structure here once again...
    dep = "video-js" if dep == "video"

    # VideoJS marker uses a dot on the CSS files.
    dep = "videojs.markers" if dep == "videojs-markers"

    if File.exists?("#{download_path}/dist/#{dep}.css")
      if minified && File.exists?("#{download_path}/package/dist/#{dep}.min.css")
        `mv #{download_path}/dist/#{dep}.min.css #{dest_path}/#{dep}.css`
      else
        `mv #{download_path}/dist/#{dep}.css #{dest_path}/#{dep}.css`
      end
    end

    # Update/create versions file for the dependency
    update_versions_yaml(required_dependencies, minified, dep_name)

    channel.send(dep_name)
  rescue ex
    channel.send(ex)
  end
end

if dependencies_to_install.empty?
  puts "#{"Player".colorize(:blue)} #{"dependencies".colorize(:green)} are satisfied"
else
  puts "#{"Resolving".colorize(:green)} #{"player".colorize(:blue)} dependencies"
  dependencies_to_install.size.times do
    result = channel.receive

    if result.is_a? Exception
      raise result
    end

    puts "#{"Fetched".colorize(:green)} #{result.colorize(:blue)}"
  end
end

# Cleanup
`rm -rf #{tmp_dir_path}`
