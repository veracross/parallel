require 'thread' # to get Thread.exclusive
require 'rbconfig'
require 'parallel/version'

module Parallel
  class DeadWorker < Exception
  end

  class ExceptionWrapper
    attr_reader :exception
    def initialize(exception)
      dumpable = Marshal.dump(exception) rescue nil
      unless dumpable
        exception = RuntimeError.new("Undumpable Exception -- #{exception.inspect}")
      end

      @exception = exception
    end
  end

  class Worker
    attr_reader :pid, :read, :write
    def initialize(read, write, pid)
      @read, @write, @pid = read, write, pid
    end

    def close_pipes
      read.close
      write.close
    end

    def wait
      Process.wait(pid)
    rescue Interrupt
      # process died
    end

    def work(index)
      begin
        Marshal.dump(index, write)
      rescue Errno::EPIPE
        raise DeadWorker
      end

      begin
        Marshal.load(read)
      rescue EOFError
        raise Parallel::DeadWorker
      end
    end
  end

  class << self
    def in_threads(options={:count => 2})
      count, options = extract_count_from_options(options)

      out = []
      threads = []

      count.times do |i|
        threads[i] = Thread.new do
          out[i] = yield(i)
        end
      end

      wait_for_threads(threads)

      out
    end

    def in_processes(options = {}, &block)
      count, options = extract_count_from_options(options)
      count ||= processor_count
      map(0...count, options.merge(:in_processes => count), &block)
    end

    def each(array, options={}, &block)
      map(array, options.merge(:preserve_results => false), &block)
      array
    end

    def each_with_index(array, options={}, &block)
      each(array, options.merge(:with_index => true), &block)
    end

    def map(array, options = {}, &block)
      array = array.to_a # turn Range and other Enumerable-s into an Array

      if options[:in_threads]
        method = :in_threads
        size = options[method]
      else
        method = :in_processes
        size = options[method] || processor_count
      end
      size = [array.size, size].min

      return work_direct(array, options, &block) if size == 0

      if method == :in_threads
        work_in_threads(array, options.merge(:count => size), &block)
      else
        work_in_processes(array, options.merge(:count => size), &block)
      end
    end

    def map_with_index(array, options={}, &block)
      map(array, options.merge(:with_index => true), &block)
    end

    def processor_count
      @processor_count ||= case RbConfig::CONFIG['host_os']
      when /darwin9/
        `hwprefs cpu_count`.to_i
      when /darwin/
        (hwprefs_available? ? `hwprefs thread_count` : `sysctl -n hw.ncpu`).to_i
      when /linux|cygwin/
        `grep -c processor /proc/cpuinfo`.to_i
      when /(open|free)bsd/
        `sysctl -n hw.ncpu`.to_i
      when /mswin|mingw/
        require 'win32ole'
        wmi = WIN32OLE.connect("winmgmts://")
        cpu = wmi.ExecQuery("select NumberOfLogicalProcessors from Win32_Processor")
        cpu.to_enum.first.NumberOfLogicalProcessors
      when /solaris2/
        `psrinfo -p`.to_i # this is physical cpus afaik
      else
        $stderr.puts "Unknown architecture ( #{RbConfig::CONFIG["host_os"]} ) assuming one processor."
        1
      end
    end

    def physical_processor_count
      @physical_processor_count ||= case RbConfig::CONFIG['host_os']
      when /darwin1/, /freebsd/
        `sysctl -n hw.physicalcpu`.to_i
      when /linux/
        `grep cores /proc/cpuinfo`[/\d+/].to_i
      when /mswin|mingw/
        require 'win32ole'
        wmi = WIN32OLE.connect("winmgmts://")
        cpu = wmi.ExecQuery("select NumberOfProcessors from Win32_Processor")
        cpu.to_enum.first.NumberOfLogicalProcessors
      else
        processor_count
      end
    end

    private

    def work_direct(array, options)
      results = []
      array.each_with_index do |e,i|
        results << (options[:with_index] ? yield(e,i) : yield(e))
      end
      results
    end

    def hwprefs_available?
      `which hwprefs` != ''
    end

    def start_result_processor(items, processor)
      if not processor
        return nil
      end

      queue = Queue.new
      thread = Thread.new do
        while i < items.length
          begin
            index, result = queue.pop
            processor.call(result, items[index], index)
            i += 1
          rescue Exception => e
            Thread.current[:exception] = e
            break
          end
        end
      end

      {:thread => thread, :queue => queue}
    end

    def finish_result_processor(processor)
      if processor
        t = processor[:thread]
        raise t[:exception] if t[:exception]
        t.join if t.alive?
      end
    end

    def notify_result(processor, results, index)
      if processor
        processor[:queue] << [index, results[index]]
      end
    end

    def work_in_threads(items, options, &block)
      results = []
      current = -1
      exception = nil

      processor = start_result_processor items, options[:with_result]

      in_threads(options[:count]) do
        # as long as there are more items, work on one of them
        loop do
          break if exception

          index = Thread.exclusive{ current+=1 }
          break if index >= items.size

          with_instrumentation items[index], index, options do
            begin
              results[index] = call_with_index(items, index, options, &block)
              notify_result processor, results, index
            rescue Exception => e
              exception = e
              break
            end
          end
        end
      end

      raise exception if exception

      finish_result_processor processor

      results
    end

    def work_in_processes(items, options, &blk)
      workers = create_workers(items, options, &blk)
      current_index = -1
      results = []
      exception = nil

      processor = start_result_processor items, options[:with_result]

      in_threads(options[:count]) do |i|
        worker = workers[i]

        begin
          loop do
            break if exception
            index = Thread.exclusive{ current_index += 1 }
            break if index >= items.size

            output = with_instrumentation items[index], index, options do
              worker.work(index)
            end

            if ExceptionWrapper === output
              exception = output.exception
            else
              results[index] = output
              notify_result processor, results, index
            end
          end
        ensure
          worker.close_pipes
          worker.wait # if it goes zombie, rather wait here to be able to debug
        end
      end

      raise exception if exception

      finish_result_processor processor

      results
    end

    def create_workers(items, options, &block)
      # Flush all file descriptors before forking, otherwise forked workers
      # may inherit buffered data, resulting in duplicate writes to files
      # when worker processes exit
      if not options[:no_flush]
        ObjectSpace.each_object(IO) do |io|
          begin
            io.flush if not io.closed?
          rescue IOError => e
            # Some long running processes throw the uninitialized stream exception
            # for some io object, but I have not determined which it is
            if e.message != 'uninitialized stream'
              raise e
            end
          end
        end
      end

      workers = []
      Array.new(options[:count]).each do
        workers << worker(items, options.merge(:started_workers => workers), &block)
      end

      kill_on_ctrl_c(workers.map(&:pid))
      workers
    end

    def worker(items, options, &block)
      # use less memory on REE
      GC.copy_on_write_friendly = true if GC.respond_to?(:copy_on_write_friendly=)

      child_read, parent_write = IO.pipe
      parent_read, child_write = IO.pipe

      pid = Process.fork do
        begin
          options.delete(:started_workers).each(&:close_pipes)

          parent_write.close
          parent_read.close

          process_incoming_jobs(child_read, child_write, items, options, &block)
        ensure
          child_read.close
          child_write.close
        end
      end

      child_read.close
      child_write.close

      Worker.new(parent_read, parent_write, pid)
    end

    def process_incoming_jobs(read, write, items, options, &block)
      while !read.eof?
        index = Marshal.load(read)
        begin
          result = call_with_index(items, index, options, &block)
          result = nil if options[:preserve_results] == false
        rescue Exception => e
          result = ExceptionWrapper.new(e)
        end
        Marshal.dump(result, write)
      end
    end

    def wait_for_threads(threads)
      threads.compact.each do |t|
        begin
          t.join
        rescue Interrupt
          # thread died, do not stop other threads
        end
      end
    end

    # options is either a Integer or a Hash with :count
    def extract_count_from_options(options)
      if options.is_a?(Hash)
        count = options[:count]
      else
        count = options
        options = {}
      end
      [count, options]
    end

    # kill all these processes (children) if user presses Ctrl+c
    def kill_on_ctrl_c(pids)
      Signal.trap :SIGINT do
        $stderr.puts 'Parallel execution interrupted, exiting ...'
        pids.compact.each do |pid|
          begin
            Process.kill(:KILL, pid)
          rescue Errno::ESRCH
            # some linux systems already automatically killed the children at this point
            # so we just ignore them not being there
          end
        end
        exit 1 # Quit with 'failed' signal
      end
    end

    def call_with_index(array, index, options, &block)
      args = [array[index]]
      args << index if options[:with_index]
      block.call(*args)
    end

    def with_instrumentation(item, index, options)
      on_start = options[:start]
      on_finish = options[:finish]
      on_start.call(item, index) if on_start
      yield
    ensure
      on_finish.call(item, index) if on_finish
    end
  end
end
