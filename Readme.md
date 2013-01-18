Run any code in parallel Processes(> use all CPUs) or Threads(> speedup blocking operations).<br/>
Best suited for map-reduce or e.g. parallel downloads/uploads.

Install
=======
    sudo gem install parallel

Usage
=====
    # 2 CPUs -> work in 2 processes (a,b + c)
    results = Parallel.map(['a','b','c']) do |one_letter|
      expensive_calculation(one_letter)
    end

    # 3 Processes -> finished after 1 run
    results = Parallel.map(['a','b','c'], :in_processes=>3){|one_letter| ... }

    # 3 Threads -> finished after 1 run
    results = Parallel.map(['a','b','c'], :in_threads=>3){|one_letter| ... }

Same can be done with `each`
    Parallel.each(['a','b','c']){|one_letter| ... }
or `each_with_index` or `map_with_index`

### Processes
 - Speedup through multiple CPUs
 - Speedup for blocking operations
 - Protects global data
 - Extra memory used ( very low on [REE](http://www.rubyenterpriseedition.com/faq.html) through `copy_on_write_friendly` )
 - Child processes are killed when your main process is killed through Ctrl+c or kill -2

### Threads
 - Speedup for blocking operations
 - Global data can be modified
 - No extra memory used

### ActiveRecord

Try either of those to get working parallel AR

```Ruby
Parallel.each(User.all, :in_threads => 8) do |user|
  ActiveRecord::Base.connection_pool.with_connection do
    user.update_attribute(:some_attribute, some_value)
  end
end

Parallel.each(User.all, :in_processes => 8) do |user|
  ActiveRecord::Base.connection.reconnect!
  user.update_attribute(:some_attribute, some_value)
end
```

Processes/Threads are workers, they grab the next piece of work when they finish

### Progress / ETA

```Ruby
require 'progressbar'
progress = ProgressBar.new("test", 100)
Parallel.map(1..100, :finish => lambda { |i, item| progress.inc }) { sleep 1 }
progress.finish
```

### Result Thread

Perform operations on the result of each item in a single thread running in the main process

```Ruby
prng = Random.new(3728921)
puts_result = lambda {|result, item, i| puts "#{i}: #{result}" }
results = Parallel.map(1..40, :in_threads => 3, :with_result => puts_result) do |item|
  sleep prng.rand(0.01..0.3)
  "result for #{item}"
end
```

### IO Flushing

When using processes, file handles are passed to the forked workers. If one of
those file descriptors has buffered data, each worker will get a copy of it, and
the buffered data will be flushed when the worker process exits. This manifests
itself as duplicate writes to files. By default, all IO objects will be flushed
before workers are forked. To prevent this behavior, set `:no_flush` to `true.

```ruby
f = File.open('/path', 'w')
f.puts "Content"
results = Parallel.map(1..20, :in_processes => 3, :no_flush => true) do |item|
  # This will cause Content to be written to the file multiple times
  f.flush
end
```

Tips
====
 - [Benchmark/Test] Disable threading/forking with `:in_threads => 0` or `:in_processes => 0`, great to test performance or to debug parallel issues

TODO
====
 - JRuby / Windows support <-> possible ?

Authors
=======

### [Contributors](https://github.com/grosser/parallel/contributors)
 - [Przemyslaw Wroblewski](http://github.com/lowang)
 - [TJ Holowaychuk](http://vision-media.ca/)
 - [Masatomo Nakano](http://twitter.com/masatomo2)
 - [Fred Wu](http://fredwu.me)
 - [mikezter](http://github.com/mikezter)
 - [Jeremy Durham](http://www.jeremydurham.com)
 - [Nick Gauthier](http://www.ngauthier.com)
 - [Andrew Bowerman](http://andrewbowerman.com)
 - [Byron Bowerman](http://me.bm5k.com/)
 - [Mikko Kokkonen](https://github.com/mikian)
 - [brian p o'rourke](https://github.com/bpo)
 - [Norio Sato]
 - [Neal Stewart](https://github.com/n-time)
 - [Jurriaan Pruis](http://github.com/jurriaan)
 - [Rob Worley](http://github.com/robworley)
 - [Tasveer Singh](https://github.com/tazsingh)

[Michael Grosser](http://grosser.it)<br/>
michael@grosser.it<br/>
License: MIT<br/>
[![Flattr](http://api.flattr.com/button/flattr-badge-large.png)](https://flattr.com/submit/auto?user_id=grosser&url=https://github.com/grosser/parallel&title=parallel&language=en_GB&tags=github&category=software)
