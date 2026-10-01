package crossbyte.io;

// Not built for the browser. This is a synchronous, seekable handle on an open file, and a browser has no such thing -- its storage APIs are asynchronous and are not addressed by byte offset. crossbyte.io.File keeps its type there and refuses the operation instead; see NoFileSystem.
#if !(js && !nodejs)

import crossbyte.core.CrossByte;
import crossbyte.errors.EOFError;
import crossbyte.errors.Error;
import crossbyte.errors.IOError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.errors.RangeError;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.OutputProgressEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ThreadEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.io.FileMode;
import crossbyte.io.IDataInput;
import crossbyte.io.IDataOutput;
import crossbyte.io._internal.FileOps;
import crossbyte.net.ObjectEncoding;
import crossbyte.sys.Worker;
import haxe.Json;
import haxe.Serializer;
import haxe.Unserializer;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import haxe.io.FPHelper;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File as HaxeFile;
import sys.io.FileInput;
import sys.io.FileOutput;
import sys.io.FileSeek;
#if js
import crossbyte._internal.js.NoMutex as Mutex;
#else
import sys.thread.Mutex;
#end
#if format
import format.amf.Reader as AMFReader;
import format.amf.Writer as AMFWriter;
import format.amf.Tools as AMFTools;
import format.amf3.Reader as AMF3Reader;
import format.amf3.Writer as AMF3Writer;
import format.amf3.Tools as AMF3Tools;
#end

/**
	A FileStream object is used to read and write files. Files can be opened synchronously
	by calling the open() method or asynchronously by calling the openAsync() method.

	The advantage of opening files asynchronously is that other code can execute while the
	read and write run on a worker thread. When opened asynchronously, progress events are
	dispatched as operations proceed.

	A File object that is opened synchronously behaves much like a ByteArray object; a file
	opened asynchronously behaves much like a Socket object. When a File object
	is opened synchronously, the caller pauses while the requested data is read from or written
	to the underlying file. When opened asynchronously, any data written to the stream is
	immediately buffered and later written to the file.

	Whether reading from a file synchronously or asynchronously, the actual read methods are
	synchronous. In both cases they read from data that is currently "available." The difference
	is that when reading synchronously all of the data is available at all times, and when
	reading asynchronously data becomes available gradually as the data streams into a read
	buffer. Either way, the data that can be synchronously read at the current moment is
	represented by the bytesAvailable property.

	An application that is processing asynchronous input typically registers for progress events
	and consumes the data as it becomes available by calling read methods. Alternatively, an
	application can simply wait until all of the data is available by registering for the complete
	event and processing the entire data set when the complete event is dispatched.

	The reads and writes keep the contract `IDataInput` and `IDataOutput` describe and `ByteArray`
	keeps, opened either way: `readByte` is signed, `readBoolean` is true for any nonzero byte,
	`writeShort` and `writeByte` keep the low bits of what they are given, a read with too little
	data throws `EOFError` and consumes nothing, and `writeBytes` clamps its range to the source.
	`endian` and `objectEncoding` start as `ByteArray.defaultEndian` and
	`ByteArray.defaultObjectEncoding` -- little-endian and HXSF unless the application changed them --
	and can be set before or after a file is opened.

	The events of an asynchronously opened file are the stream's own -- `progress`,
	`outputProgress`, `complete`, `ioError`, `close` -- with the stream as their target. Where there
	are no threads (Node), a file can be opened asynchronously only to read.
**/
@:access(crossbyte.io.ByteArray)
@:access(crossbyte.io.ByteArrayData)
@:access(crossbyte.io.File)
class FileStream extends EventDispatcher implements IDataInput implements IDataOutput {
	/**
		Returns the number of bytes of data available for reading in the input buffer. User code
		must call bytesAvailable to ensure that sufficient data is available before trying to read
		it with one of the read methods.
	**/
	public var bytesAvailable(get, never):Int;

	/**
		The byte order for the data, either the BIG_ENDIAN or LITTLE_ENDIAN constant from the Endian
		class.

		`ByteArray.defaultEndian` when the stream is made, as for every CrossByte `IDataInput` and
		`IDataOutput` -- little-endian unless the application changed it. It holds across `open()` and
		`openAsync()`, and changing it while a file is open applies to what is read and written next.

		@default ByteArray.defaultEndian
	**/
	public var endian(get, set):Endian;

	/**
		Specifies whether the HXSF, JSON, AMF3 or AMF0 format is used when writing or reading binary
		data by using the readObject() or writeObject() method.

		The value is a constant from the ObjectEncoding class, and starts as
		`ByteArray.defaultObjectEncoding`: `HXSF` unless the application changed it. `JSON` is always
		available. `AMF0` and `AMF3` are read and written only when the optional `format` haxelib is on
		the build -- `-lib format`. Asking for one this build cannot do throws, rather than reading
		`null` or writing nothing.

		@default ByteArray.defaultObjectEncoding
	**/
	public var objectEncoding:ObjectEncoding;

	/**
		The current position in the file.

		This value is modified in any of the following ways:

		* When you set the property explicitly
		* When reading from the FileStream object (by using one of the read methods)
		* When writing to the FileStream object

		A position is a `UInt` read and set as an `Int`: a file can be addressed up to 2,147,483,647
		bytes (2 GB), and `File.size` refuses a larger one rather than answering wrongly. (AIR's
		position is a Number, for files past 2^32 bytes; this one is not.)

		When reading a file asyncronously, if you set the position property, the application begins
		filling the read buffer with the data starting at the specified position, and the bytesAvailable
		property may be set to 0. Wait for a complete event before using a read method to read data;
		or wait for a progress event and check the bytesAvailable property before using a read method.

		When writing a file asynchronously, setting the position moves where the next write goes, as
		it does when writing synchronously; in `APPEND` mode every write goes to the end.
	**/
	@:isVar public var position(get, set):UInt;

	/**
		The minimum amount of data to read from disk when reading files asynchronously.

		This property specifies how much data an asynchronous stream attempts to read beyond the current
		position. Data is read in whole blocks of 4,096 bytes: set to 9,000, the stream reads ahead
		three blocks, 12,288 bytes. The default value of this property is infinity: by default a file
		that is opened to read asynchronously reads as far as the end of the file, and keeps what it has
		read, so the stream can seek back without reading it again. A finite value bounds the buffer: what
		has been read is let go of as the reader moves on.

		Reading data from the read buffer does not change the value of the readAhead property. When you
		read data from the buffer, new data is read in to refill the read buffer.

		The readAhead property has no effect on a file that is opened synchronously, nor where there
		are no threads (Node), where the file is read to its end at once.

		As data is read in asynchronously, the FileStream object dispatches progress events. In the event
		handler method for the progress event, check to see that the required number of bytes is available
		(by checking the bytesAvailable property), and then read the data from the read buffer by using a
		read method.
	**/
	public var readAhead(default, set):Float = Math.POSITIVE_INFINITY;

	/**
		The isWriting property returns a bool used to identify the write state of asynchronous Update,
		Append, or Write streams. If isWrite is true, data is actively being written from the buffer.
	**/
	public var isWriting(default, null):Bool = false;

	@:noCompletion private var __input:FileInput;
	@:noCompletion private var __output:FileOutput;
	@:noCompletion private var __fileMode:FileMode;
	@:noCompletion private var __file:File;
	@:noCompletion private var __isOpen:Bool = false;
	@:noCompletion private var __isAsync:Bool = false;
	@:noCompletion private var __endian:Endian;
	@:noCompletion private var __positionDirty:Bool = false;
	// Eight bytes to read a number into, or write one from, in the stream's
	// byte order: one call into the file instead of one per byte, and no
	// allocation per number.
	@:noCompletion private var __scratch:Bytes;
	// Everything about an asynchronously opened file, its worker included.
	// A reopened stream gets a new one, so a worker still finishing the last
	// file never touches the next.
	@:noCompletion private var __async:Null<AsyncFile>;
	// The most an asynchronous stream reads from the file at once.
	@:noCompletion private var __pageSize:Int = 4096000;
	// Where an asynchronous write began in its segment; see __endAsyncWrite.
	@:noCompletion private var __segmentStart:Int = 0;

	/**
		Creates a FileStream object. Use the open() or openAsync() method to open a file.
	**/
	public function new() {
		super();
		__endian = ByteArray.defaultEndian;
		objectEncoding = ByteArray.defaultObjectEncoding;
		__scratch = Bytes.alloc(8);
	}

	/**
		 Closes the FileStream object.

		You cannot read or write any data after you call the close() method. If the file was
		opened asynchronously (the FileStream object used the openAsync() method to open the
		file), calling the close() method causes the object to dispatch the close event.

		Closing the application automatically closes all files associated with FileStream
		objects in the application. However, it is best to register for a closed event on
		all FileStream objects opened asynchronously that have pending data to write, before
		closing the application (to ensure that data is written).

		You can reuse the FileStream object by calling the open() or the openAsync() method.
		This closes any file associated with the FileStream object, but the object does not
		dispatch the close event.

		For a FileStream object opened asynchronously (by using the openAsync() method), even
		if you call the close() event for a FileStream object and delete properties and variables
		that reference the object, the FileStream object is not garbage collected as long as
		there are pending operations and event handlers are registered for their completion. In
		particular, an otherwise unreferenced FileStream object persists as long as any of the
		following are still possible:

		For file reading operations, the end of the file has not been reached (and the complete
		event has not been dispatched).
		Output data is still available to written, and output-related events (such as the
		outputProgress event or the ioError event) have registered event listeners.

		An asynchronous file closed while it is still being read stops reading: no `complete`
		follows, only `close`. One closed with writes still pending writes them first.

		@event close    			The file, which was opened asynchronously, is closed.
	**/
	public function close():Void {
		if (!__isOpen) {
			return;
		}

		var session:Null<AsyncFile> = __async;

		if (session == null) {
			__releaseSync();
			return;
		}

		session.mutex.acquire();
		var already:Bool = session.closing;
		session.closing = true;
		session.mutex.release();

		if (already) {
			return;
		}

		if (session.worker != null && session.worker.running) {
			// The worker writes what is pending, or stops reading, lets go of
			// the file and says so; `close` follows that.
			return;
		}

		__finishAsyncClose(session);
	}

	/**
		 Opens the FileStream object synchronously, pointing to the file specified by the
		 file parameter.

		If the FileStream object is already open, calling the method closes the file before
		opening and no further events (including close) are delivered for the previously opened
		file.

		On systems that support file locking, a file opened in "write" or "update" mode
		(FileMode.WRITE or FileMode.UPDATE) is not readable until it is closed. CrossByte locks
		nothing: on every platform it runs on, another reader sees the file as it is.

		Once you are done performing operations on the file, call the close() method of the
		FileStream object. Some operating systems limit the number of concurrently open files.
		@param 		file The File object specifying the file to open.
		@param 		 A string from the FileMode class that defines the capabilities of the
		FileStream, such as the ability to read from or write to the file.
		@throws 	IOError The file does not exist; you do not have adequate permissions to
		open the file; you are opening a file for read access, and you do not have read
		permissions; or you are opening a file for write access, and you do not have write
		permissions.
	 */
	public function open(file:File, fileMode:FileMode):Void {
		__closeQuietly();
		__file = file;
		__fileMode = fileMode;
		__openSync();
	}

	/**
		Opens the FileStream object asynchronously, pointing to the file specified by the file
		parameter.

		If the FileStream object is already open, calling the method closes the file before opening
		and no further events (including close) are delivered for the previously opened file.

		If the fileMode parameter is set to FileMode.READ or FileMode.UPDATE, data is read into
		the input buffer as soon as the file is opened, and progress and open events are dispatched
		as the data is read to the input buffer.

		On systems that support file locking, a file opened in "write" or "update" mode (FileMode.WRITE
		or FileMode.UPDATE) is not readable until it is closed. CrossByte locks nothing.

		Once you are done performing operations on the file, call the close() method of the FileStream
		object. Some operating systems limit the number of concurrently open files.

		A file that cannot be opened is reported as an `ioError` event, after this returns, so a
		listener added straight afterwards hears it; the stream is then not open.

		In `UPDATE` mode the file is read into the buffer as in `READ` mode, reads come from it, and
		a write lands in the file and in the buffer at the stream's position, so what is read
		afterwards is what was written.

		@param 		file The File object specifying the file to open.
		@param 		 A string from the FileMode class that defines the capabilities of the
		FileStream, such as the ability to read from or write to the file.
		@event 		ioError The file does not exist; you do not have adequate permissions to open the
		file; you are opening a file for read access, and you do not have read permissions; or you are
		opening a file for write access, and you do not have write permissions.
		@event 		progress Dispatched as data is read to the input buffer. (The file must be opened
		with the fileMode parameter set to FileMode.READ or FileMode.UPDATE.)
		@event		complete The file data has been read to the input buffer. (The file must be opened
		with the fileMode parameter set to FileMode.READ or FileMode.UPDATE.)
		@throws 	IllegalOperationError `fileMode` writes, and the target has no threads to write
		with (Node).
	 */
	public function openAsync(file:File, fileMode:FileMode):Void {
		#if !target.threaded
		if (fileMode != READ) {
			// The writer is a worker that waits for writes. With no thread of
			// its own it ran inside this call, waiting for writes this call's
			// caller could never make, and never returned.
			throw new IllegalOperationError("openAsync can only read on this target: writing asynchronously needs a thread for the writer, and there is none here. Use open() and write synchronously.");
		}
		#end

		// It made the new worker first and then closed the open stream, which
		// disposed of the new worker: a Null Access, whether what was open had
		// been opened with open() or openAsync().
		__closeQuietly();
		__file = file;
		__fileMode = fileMode;

		var session:AsyncFile = new AsyncFile(file, fileMode, __endian, readAhead, __pageSize);

		try {
			session.openHandles();
		} catch (e:Dynamic) {
			session.releaseHandles();
			// An event, as documented, which it was not: this threw. Posted,
			// so that a listener added after this returns hears it.
			var text:String = 'Could not open "${file.nativePath}" to ${Std.string(fileMode)}: ${__describe(e)}';
			if (!__postIoError(text, 3003)) {
				throw new IOError(text);
			}
			return;
		}

		__async = session;
		__isAsync = true;
		__isOpen = true;
		__positionDirty = false;

		var worker:Worker = new Worker();
		session.worker = worker;
		// Closures, not methods: each worker belongs to one file, and what it
		// says about another is dropped by the session check in each.
		worker.addEventListener(ThreadEvent.PROGRESS, (event:ThreadEvent) -> __onAsyncNotice(session, event.message));
		worker.addEventListener(ThreadEvent.COMPLETE, (event:ThreadEvent) -> __onAsyncFinished(session, event.message));
		worker.addEventListener(ThreadEvent.ERROR, (event:ThreadEvent) -> __onAsyncFailed(session, event.message));
		worker.doWork = session.run;
		worker.run();
	}

	/** Dispatches what the worker reports, if it reports on the file now open. **/
	@:noCompletion private function __onAsyncNotice(session:AsyncFile, notice:AsyncNotice):Void {
		if (session != __async) {
			return;
		}

		session.mutex.acquire();
		var closing:Bool = session.closing;
		session.mutex.release();

		switch (notice) {
			case Read(_, _) | Loaded if (closing):
				// Reading stopped when close() was called; what it had got to
				// is not news.
			case Read(loaded, total):
				dispatchEvent(new ProgressEvent(ProgressEvent.PROGRESS, loaded, total));
			case Wrote(pending, total):
				isWriting = pending > 0;
				dispatchEvent(new OutputProgressEvent(OutputProgressEvent.OUTPUT_PROGRESS, pending, total));
			case Loaded:
				dispatchEvent(new Event(Event.COMPLETE));
			case Failed(text):
				dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, text));
			case Finished(_):
		}
	}

	/** The worker has stopped: for good once the file closes, or until a seek needs more read. **/
	@:noCompletion private function __onAsyncFinished(session:AsyncFile, notice:AsyncNotice):Void {
		if (session != __async) {
			return;
		}

		session.mutex.acquire();
		var closing:Bool = session.closing;
		var reload:Bool = session.reloadPending;
		session.reloadPending = false;
		session.mutex.release();

		if (closing) {
			// No complete for a file closed while it was being read.
			__finishAsyncClose(session);
			return;
		}

		switch (notice) {
			case Finished(true):
				dispatchEvent(new Event(Event.COMPLETE));
			default:
		}

		if (reload && session == __async && session.worker != null) {
			__restartLoader(session);
		}
	}

	/** The worker threw: the file could not be read or written. **/
	@:noCompletion private function __onAsyncFailed(session:AsyncFile, error:Dynamic):Void {
		if (session != __async) {
			return;
		}

		dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, "The file could not be read or written: " + __describe(error)));

		session.mutex.acquire();
		var closing:Bool = session.closing;
		session.mutex.release();

		if (closing) {
			__finishAsyncClose(session);
		}
	}

	/** Starts reading again after a seek outside what the buffer holds. **/
	@:noCompletion private function __restartLoader(session:AsyncFile):Void {
		var worker:Null<Worker> = session.worker;

		if (worker == null) {
			return;
		}

		if (worker.running) {
			session.mutex.acquire();
			session.reloadPending = true;
			session.mutex.release();
			return;
		}

		// cancel() cleared the body along with everything else.
		worker.doWork = session.run;
		worker.run();
	}

	@:noCompletion private function __finishAsyncClose(session:AsyncFile):Void {
		if (session != __async) {
			return;
		}

		session.releaseHandles();
		__disposeWorker(session);
		__async = null;
		__isOpen = false;
		__isAsync = false;
		isWriting = false;
		position = 0;
		__positionDirty = false;
		dispatchEvent(new Event(Event.CLOSE));
	}

	/**
		Whatever is open, closed without a `close` event: what opening another
		file does first. Pending asynchronous writes are still written, and
		waited for, briefly, so that the next file is not opened while the
		last is still being written.
	**/
	@:noCompletion private function __closeQuietly():Void {
		if (!__isOpen) {
			return;
		}

		var session:Null<AsyncFile> = __async;

		if (session != null) {
			__async = null;
			session.mutex.acquire();
			session.abandoned = true;
			session.mutex.release();

			var worker:Null<Worker> = session.worker;
			var running:Bool = worker != null && worker.running;
			__disposeWorker(session);

			if (running) {
				#if target.threaded
				var deadline:Float = haxe.Timer.stamp() + 10;

				while (!session.isFinished() && haxe.Timer.stamp() < deadline) {
					crossbyte._internal.system.Sleep.sleep(0.001);
				}
				#end
			}

			if (!running || session.isFinished()) {
				session.releaseHandles();
			}
		} else {
			__releaseSync();
		}

		__isOpen = false;
		__isAsync = false;
		isWriting = false;
		position = 0;
		__positionDirty = false;
	}

	@:noCompletion private function __disposeWorker(session:AsyncFile):Void {
		var worker:Null<Worker> = session.worker;

		if (worker == null) {
			return;
		}

		session.worker = null;
		worker.removeAllListeners();
		// Without cleaning: cleaning clears the body, and a worker whose
		// thread has not yet reached it would then never run -- and never
		// write what was pending, nor let go of the file.
		worker.cancel(false);
	}

	@:noCompletion private function __releaseSync():Void {
		if (__output != null) {
			try {
				__output.close();
			} catch (_:Dynamic) {}
			__output = null;
		}

		if (__input != null) {
			try {
				__input.close();
			} catch (_:Dynamic) {}
			__input = null;
		}

		__isOpen = false;
		position = 0;
		__positionDirty = false;
	}

	/**
	 * Reads a Boolean value from the file stream, byte stream, or byte array. A single byte is read
	 * and true is returned if the byte is nonzero, false otherwise.
	 *
	 * @return 		A Boolean value, true if the byte is nonzero, false otherwise.
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readBoolean():Bool {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				var value:Bool = buffer.readBoolean();
				__async.mutex.release();
				return value;
			} catch (e:Dynamic) {
				// Nothing consumed by a read that fails, as on a synchronous stream.
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		// Any nonzero byte, as documented and as ByteArray reads one. It was
		// `== 1`, so a 2 read as false.
		return __take(1).get(0) != 0;
	}

	/**
	 * Reads a signed byte from the file stream, byte stream, or byte array.
	 *
	 * @return The returned value is in the range -128 to 127.
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 			EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readByte():Int {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				var value:Int = buffer.readByte();
				__async.mutex.release();
				return value;
			} catch (e:Dynamic) {
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		// Signed, as documented. It was the unsigned byte: 0xFF read as 255.
		var value:Int = __take(1).get(0);
		return value >= 0x80 ? value - 0x100 : value;
	}

	/**
	 * Reads the number of data bytes, specified by the length parameter, from the file stream, byte
	 * stream, or byte array. The bytes are read into the ByteArray objected specified by the bytes
	 * parameter, starting at the position specified by offset.
	 *
	 * @param	bytes
	 * @param	offset
	 * @param	length
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readBytes(bytes:ByteArray, offset:UInt = 0, length:UInt = 0):Void {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				buffer.readBytes(bytes, offset, length);
				__async.mutex.release();
				return;
			} catch (e:Dynamic) {
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		if (length == 0) {
			var at:Int = __input.tell();
			__input.seek(0, FileSeek.SeekEnd);
			length = __input.tell() - at;
			__input.seek(at, FileSeek.SeekBegin);
		}

		var byteArrayData:ByteArrayData = bytes;
		if (byteArrayData.length < offset + length) {
			byteArrayData.__resize(offset + length);
		}

		// Read straight into the destination. This used to allocate a fresh
		// `Bytes` per call and copy it across, which at a 64 KB slice is
		// roughly sixteen thousand transient allocations and a second copy
		// of every byte for each gigabyte streamed.
		var read:Int = __readFully(byteArrayData, offset, length);

		__positionDirty = true;

		if (read < length) {
			// The contract above: not enough data is an EOFError. A short read
			// used to be padded out with zeros and reported as success, so a
			// chunked copy of a 1 MB file came out 65,436 bytes longer, the
			// tail of it zeros, with nothing to say where the data ended.
			// Nothing is consumed, so the caller can ask again for what is
			// there.
			if (read > 0) {
				__input.seek(-read, FileSeek.SeekCur);
			}

			throw new EOFError('Asked for $length bytes with ${read} left in the file.');
		}
	}

	/**
	 * Reads an IEEE 754 double-precision floating point number from the file stream, byte stream, or
	 * byte array.
	 *
	 * @return An IEEE 754 double-precision floating point number
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readDouble():Float {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				var value:Float = buffer.readDouble();
				__async.mutex.release();
				return value;
			} catch (e:Dynamic) {
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		var bytes:Bytes = __take(8);
		return __endian == LITTLE_ENDIAN ? FPHelper.i64ToDouble(__i32(bytes, 0), __i32(bytes, 4)) : FPHelper.i64ToDouble(__i32(bytes, 4),
			__i32(bytes, 0));
	}

	/**
	 * Reads an IEEE 754 single-precision floating point number from the file stream, byte stream, or byte array.
	 *
	 * @return		An IEEE 754 single-precision floating point number.
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readFloat():Float {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				var value:Float = buffer.readFloat();
				__async.mutex.release();
				return value;
			} catch (e:Dynamic) {
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		return FPHelper.i32ToFloat(__i32(__take(4), 0));
	}

	/**
	 * Reads a signed 32-bit integer from the file stream, byte stream, or byte array.
	 *
	 * @return The returned value is in the range -2147483648 to 2147483647.
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readInt():Int {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				var value:Int = buffer.readInt();
				__async.mutex.release();
				return value;
			} catch (e:Dynamic) {
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		return __i32(__take(4), 0);
	}

	/**
	 * Reads a multibyte string of specified length from the file stream, byte stream, or byte array.
	 *
	 * The bytes are read as UTF-8, whatever `charSet` names, as `ByteArray.readMultiByte` reads them:
	 * CrossByte reads and writes text as UTF-8 everywhere, and carries no tables for other character
	 * sets. `charSet` is accepted so that code written for AIR compiles; a file in another encoding has
	 * to be decoded by the caller, from `readBytes`.
	 *
	 * @param		length The number of bytes from the byte stream to read.
	 * @param		charSet Ignored: the bytes are read as UTF-8.
	 * @return		UTF-8 encoded string.
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readMultiByte(length:Int, charSet:String):String {
		return readUTFBytes(length);
	}

	/**
	 * Reads an object from the file stream, byte stream, or byte array, in the format
	 * `objectEncoding` names, as `writeObject` wrote it.
	 *
	 * One object, and only its bytes: what follows it in the file is left for the next read. HXSF and
	 * JSON are a 32-bit length in the stream's byte order and then that many bytes of UTF-8; AMF0 and
	 * AMF3 are their own encodings, which say where they end.
	 *
	 * @return The deserialized object
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readObject():Dynamic {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				var value:Dynamic = __readObjectFrom(buffer);
				__async.mutex.release();
				return value;
			} catch (e:Dynamic) {
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		__positionDirty = true;

		switch (objectEncoding) {
			#if format
			case AMF0 | AMF3:
				// Read through the file itself, which stops where the object
				// does. Every byte from here to the end of the file was read
				// into a buffer and the rest thrown away, so a second object
				// was never there to read.
				var start:Int = __input.tell();
				try {
					return objectEncoding == AMF0 ? ByteArrayData.unwrapAMFValue(new AMFReader(__input).read()) : ByteArrayData.unwrapAMF3Value(new AMF3Reader(__input).read());
				} catch (_:haxe.io.Eof) {
					__input.seek(start, FileSeek.SeekBegin);
					throw new EOFError("The object runs past the end of the file.");
				}
			#end

			case HXSF | JSON:
				var length:Int = __i32(__take(4), 0);

				if (length < 0 || length > __getStreamBytesAvailable()) {
					__input.seek(-4, FileSeek.SeekCur);
					throw new EOFError("The object runs past the end of the file.");
				}

				var body:Bytes = Bytes.alloc(length);
				var read:Int = __readFully(body, 0, length);

				if (read < length) {
					__input.seek(-(read + 4), FileSeek.SeekCur);
					throw new EOFError("The object runs past the end of the file.");
				}

				return __parseObject(crossbyte._internal.Utf8.stringOf(body, 0, length));

			default:
				throw new Error(ByteArrayData.__unsupportedEncoding(objectEncoding));
		}
	}

	/** One object from the asynchronous read buffer, under its lock. **/
	@:noCompletion private function __readObjectFrom(buffer:ByteArray):Dynamic {
		var start:Int = buffer.position;

		switch (objectEncoding) {
			#if format
			case AMF0 | AMF3:
				var input:BytesInput = new BytesInput(buffer, start, buffer.length - start);
				try {
					var value:Dynamic = objectEncoding == AMF0 ? ByteArrayData.unwrapAMFValue(new AMFReader(input).read()) : ByteArrayData.unwrapAMF3Value(new AMF3Reader(input).read());
					buffer.position = input.position;
					return value;
				} catch (_:haxe.io.Eof) {
					buffer.position = start;
					throw new EOFError("The object runs past what has been read.");
				}
			#end

			case HXSF | JSON:
				if (buffer.bytesAvailable < 4) {
					throw new EOFError("The object runs past what has been read.");
				}

				buffer.endian = __endian;
				var length:Int = buffer.readUnsignedInt();

				if (length < 0 || length > buffer.bytesAvailable) {
					buffer.position = start;
					throw new EOFError("The object runs past what has been read.");
				}

				return __parseObject(buffer.readUTFBytes(length));

			default:
				throw new Error(ByteArrayData.__unsupportedEncoding(objectEncoding));
		}
	}

	@:noCompletion private function __parseObject(text:String):Dynamic {
		return objectEncoding == JSON ? Json.parse(text) : Unserializer.run(text);
	}

	/**
	 * Reads a signed 16-bit integer from the file stream, byte stream, or byte array.
	 *
	 * @return The returned value is in the range -32768 to 32767.
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readShort():Int {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				var value:Int = buffer.readShort();
				__async.mutex.release();
				return value;
			} catch (e:Dynamic) {
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		var value:Int = __u16(__take(2));
		return value >= 0x8000 ? value - 0x10000 : value;
	}

	/**
	 * Reads an unsigned byte from the file stream, byte stream, or byte array.
	 *
	 * @return The returned value is in the range 0 to 255.
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readUnsignedByte():UInt {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				var value:Int = buffer.readUnsignedByte();
				__async.mutex.release();
				return value;
			} catch (e:Dynamic) {
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		return __take(1).get(0);
	}

	/**
	 * Reads an unsigned 32-bit integer from the file stream, byte stream, or byte array.
	 *
	 * @return The returned value is in the range 0 to 4294967295.
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readUnsignedInt():UInt {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				var value:Int = buffer.readUnsignedInt();
				__async.mutex.release();
				return value;
			} catch (e:Dynamic) {
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		return __i32(__take(4), 0);
	}

	/**
	 * Reads an unsigned 16-bit integer from the file stream, byte stream, or byte array.
	 *
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readUnsignedShort():UInt {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				var value:Int = buffer.readUnsignedShort();
				__async.mutex.release();
				return value;
			} catch (e:Dynamic) {
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		return __u16(__take(2));
	}

	/**
		*  Reads a UTF-8 string from the file stream, byte stream, or byte array. The string is assumed to be
		* prefixed with an unsigned short indicating the length in bytes.

				This method is similar to the readUTF() method in the Java® IDataInput interface.
		* @return A UTF-8 string produced by the byte representation of characters.
		* @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
		* for files opened for asynchronous operations (by using the openAsync() method).
		* @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
		* with read capabilities; or for a file that has been opened for synchronous operations (by using
		* the open() method), the file cannot be read (for example, because the file is missing).
		* @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
		* (specified by the bytesAvailable property).
	 */
	public function readUTF():String {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				var value:String = buffer.readUTF();
				__async.mutex.release();
				return value;
			} catch (e:Dynamic) {
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		var length:Int = __u16(__take(2));
		var body:Bytes = Bytes.alloc(length);
		var read:Int = __readFully(body, 0, length);

		if (read < length) {
			__input.seek(-(read + 2), FileSeek.SeekCur);
			throw new EOFError('The string is $length bytes, and ${read} are left in the file.');
		}

		return crossbyte._internal.Utf8.stringOf(body, 0, length);
	}

	/**
	 * Reads a sequence of UTF-8 bytes from the byte stream or byte array and returns a string.
	 * @param		length The number of bytes to read.
	 * @return A UTF-8 string produced by the byte representation of characters of the specified length.
	 * @event 		ioError The file cannot be read or the file is not open. This event is dispatched only
	 * for files opened for asynchronous operations (by using the openAsync() method).
	 * @throws 		IOError The file has not been opened; the file has been opened, but it was not opened
	 * with read capabilities; or for a file that has been opened for synchronous operations (by using
	 * the open() method), the file cannot be read (for example, because the file is missing).
	 * @throws 		EOFError The position specfied for reading data exceeds the number of bytes available
	 * (specified by the bytesAvailable property).
	 */
	public function readUTFBytes(length:Int):String {
		__checkIfReadable();

		if (__isAsync) {
			var buffer:ByteArray = __lockReadBuffer();
			var start:Int = buffer.position;
			try {
				var value:String = buffer.readUTFBytes(length);
				__async.mutex.release();
				return value;
			} catch (e:Dynamic) {
				buffer.position = start;
				__async.mutex.release();
				throw e;
			}
		}

		if (length < 0) {
			throw new EOFError('Asked for $length bytes.');
		}

		var body:Bytes = Bytes.alloc(length);
		var read:Int = __readFully(body, 0, length);

		if (read < length) {
			if (read > 0) {
				__input.seek(-read, FileSeek.SeekCur);
			}
			throw new EOFError('Asked for $length bytes with ${read} left in the file.');
		}

		return crossbyte._internal.Utf8.stringOf(body, 0, length);
	}

	/**
	 * Truncates the file at the position specified by the position property of the FileStream object.
	 *
	 * Bytes from the position specified by the position property to the end of the file are deleted.
	 * The file must be open for writing. A position past the end extends the file with zeros. The
	 * stream stays open, at the same position; an asynchronous stream truncates after the writes
	 * already pending, and its read buffer loses what was past the position too.
	 *
	 * @throws 		IllegalOperationError The file is not open for writing.
	 */
	public function truncate():Void {
		__checkIfOpen();

		// It checked only that the stream was open, so a stream opened to read
		// cut the file it was reading.
		if (__fileMode == READ) {
			throw new IllegalOperationError("The file is open to read; truncate() needs it open to write.");
		}

		var at:Int = position;

		if (__isAsync) {
			__async.truncate(at);
			isWriting = true;
			return;
		}

		// In place, through the system's truncate. It closed the stream, read
		// the whole file into memory, wrote back the part it kept and opened
		// the file again: a file's size of memory, and a window in which a
		// crash left the file empty.
		try {
			__output.flush();
			FileOps.truncate(__file.nativePath, at);
		} catch (e:Dynamic) {
			throw new IOError('Could not truncate "${__file.nativePath}" at $at: ${__describe(e)}');
		}

		__output.seek(at, FileSeek.SeekBegin);
		if (__input != null) {
			__input.seek(at, FileSeek.SeekBegin);
		}

		position = at;
		__positionDirty = false;
	}

	/**
	 * Writes a Boolean value. A single byte is written according to the value parameter, either
	 * 1 if true or 0 if false.
	 *
	 * @param		value  A Boolean value determining which byte is written. If the parameter is
	 * true, 1 is written; if false, 0 is written.
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeBoolean(value:Bool):Void {
		writeByte(value ? 1 : 0);
	}

	/**
	 * Writes a byte. The low 8 bits of the parameter are used; the high 24 bits are ignored.
	 *
	 * @param	value A byte value as an integer.
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeByte(value:Int):Void {
		__checkIfWritable();

		if (__isAsync) {
			var segment:ByteArray = __beginAsyncWrite();
			segment.writeByte(value);
			__endAsyncWrite(segment);
			return;
		}

		__scratch.set(0, value);
		__writeScratch(1);
	}

	/**
	 *  Writes a sequence of bytes from the specified byte array, bytes, starting at the byte specified
	 * by offset (using a zero-based index) with a length specified by length, into the file stream,
	 * byte stream, or byte array.
	 *
	 * If the length parameter is omitted, the default length of 0 is used and the entire buffer starting at
	 * offset is written. If the offset parameter is also omitted, the entire buffer is written.
	 *
	 * If the offset or length parameter is out of range, they are clamped to the beginning and end of the bytes array.
	 *
	 * @param		bytes The byte array to write.
	 * @param		offset A zero-based index specifying the position into the array to begin writing.
	 * @param		length An unsigned integer specifying how far into the buffer to write.
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeBytes(bytes:ByteArray, offset:Int = 0, length:Int = 0):Void {
		__checkIfWritable();

		// Clamped, as documented and as ByteArray clamps. An offset or length
		// past the source went straight to the file layer, which read past the
		// source's end -- on the interpreter that ended the process.
		var available:Int = bytes == null ? 0 : bytes.length;
		if (offset < 0) {
			offset = 0;
		}
		if (available == 0 || offset >= available) {
			return;
		}
		var remaining:Int = available - offset;
		if (length <= 0 || length > remaining) {
			length = remaining;
		}

		if (__isAsync) {
			var segment:ByteArray = __beginAsyncWrite();
			segment.writeBytes(bytes, offset, length);
			__endAsyncWrite(segment);
			return;
		}

		__output.writeFullBytes(bytes, offset, length);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
	}

	/**
	 * Writes an IEEE 754 double-precision (64-bit) floating point number.
	 *
	 * @param		value A double-precision (64-bit) floating point number.
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeDouble(value:Float):Void {
		__checkIfWritable();

		if (__isAsync) {
			var segment:ByteArray = __beginAsyncWrite();
			segment.writeDouble(value);
			__endAsyncWrite(segment);
			return;
		}

		var bits = FPHelper.doubleToI64(value);
		if (__endian == LITTLE_ENDIAN) {
			__put32(0, bits.low);
			__put32(4, bits.high);
		} else {
			__put32(0, bits.high);
			__put32(4, bits.low);
		}
		__writeScratch(8);
	}

	/**
	 * Writes an IEEE 754 single-precision (32-bit) floating point number.
	 *
	 * @param		A single-precision (32-bit) floating point number.
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeFloat(value:Float):Void {
		__checkIfWritable();

		if (__isAsync) {
			var segment:ByteArray = __beginAsyncWrite();
			segment.writeFloat(value);
			__endAsyncWrite(segment);
			return;
		}

		__put32(0, FPHelper.floatToI32(value));
		__writeScratch(4);
	}

	/**
	 * Writes a 32-bit signed integer.
	 *
	 * @param		value A byte value as a signed integer
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeInt(value:Int):Void {
		__checkIfWritable();

		if (__isAsync) {
			var segment:ByteArray = __beginAsyncWrite();
			segment.writeInt(value);
			__endAsyncWrite(segment);
			return;
		}

		__put32(0, value);
		__writeScratch(4);
	}

	/**
	 * Writes a multibyte string to the file stream, byte stream, or byte array, using the specified
	 * character set.
	 *
	 * The string is written as UTF-8, whatever `charSet` names, as `ByteArray.writeMultiByte` writes
	 * it: CrossByte carries no tables for other character sets. `charSet` is accepted so that code
	 * written for AIR compiles; to write another encoding, encode the bytes yourself and use
	 * `writeBytes`.
	 *
	 * @param		value The string value to be written.
	 * @param		charSet Ignored: the string is written as UTF-8.
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeMultiByte(value:String, charSet:String):Void {
		writeUTFBytes(value);
	}

	/**
	 * Writes an object to the file stream, byte stream, or byte array, in AMF, HXSF, or JSON serialized
	 * format. The optional `format` haxelib -- `-lib format` -- is required for AMF.
	 *
	 * HXSF and JSON are written as a 32-bit length, in the stream's byte order, and then that many bytes
	 * of UTF-8, as `ByteArray.writeObject` writes them, so either reads what the other wrote. There is
	 * no limit below 2 GB on an object's size. (A 16-bit length was written before 1.0, which capped an
	 * object at 65,535 bytes; files written that way do not read back.)
	 *
	 * @param		object The object to be serialized.
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeObject(object:Dynamic):Void {
		__checkIfWritable();

		// Encoded first, so that one which cannot be leaves nothing behind.
		var encoded:Bytes = __encodeObject(object);

		if (__isAsync) {
			var segment:ByteArray = __beginAsyncWrite();
			segment.writeBytes(ByteArray.fromBytes(encoded), 0, encoded.length);
			__endAsyncWrite(segment);
			return;
		}

		__output.writeFullBytes(encoded, 0, encoded.length);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
	}

	/**
		`object` as `writeObject` writes it. The asynchronous stream wrote
		through its buffer's own `writeObject`, which ignored the stream's
		`objectEncoding` -- HXSF whatever it said -- and its byte order.
	**/
	@:noCompletion private function __encodeObject(object:Dynamic):Bytes {
		switch (objectEncoding) {
			#if format
			case AMF0:
				var output:BytesOutput = new BytesOutput();
				new AMFWriter(output).write(AMFTools.encode(object));
				return output.getBytes();

			case AMF3:
				var output:BytesOutput = new BytesOutput();
				new AMF3Writer(output).write(AMF3Tools.encode(object));
				return output.getBytes();
			#end

			case HXSF | JSON:
				var text:String = objectEncoding == JSON ? Json.stringify(object) : Serializer.run(object);
				var body:Bytes = crossbyte._internal.Utf8.bytesOf(text);
				var encoded:Bytes = Bytes.alloc(body.length + 4);
				var length:Int = body.length;

				if (__endian == LITTLE_ENDIAN) {
					encoded.setInt32(0, length);
				} else {
					encoded.set(0, length >>> 24);
					encoded.set(1, length >> 16);
					encoded.set(2, length >> 8);
					encoded.set(3, length);
				}

				encoded.blit(4, body, 0, length);
				return encoded;

			default:
				throw new Error(ByteArrayData.__unsupportedEncoding(objectEncoding));
		}
	}

	/**
	 * Writes a 16-bit integer. The low 16 bits of the parameter are used; the high 16 bits are ignored.
	 *
	 * @param		value  A byte value as an integer.
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeShort(value:Int):Void {
		__checkIfWritable();

		if (__isAsync) {
			var segment:ByteArray = __beginAsyncWrite();
			segment.writeShort(value);
			__endAsyncWrite(segment);
			return;
		}

		// The low sixteen bits, as documented. writeInt16 threw Overflow for
		// anything outside -32768..32767, so 0xFFFF -- which writeShort is
		// for as much as -1 is -- could not be written.
		__put16(value);
		__writeScratch(2);
	}

	/**
	 * Writes a 32-bit unsigned integer.
	 *
	 * @param		value A byte value as an unsigned integer.
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeUnsignedInt(value:UInt):Void {
		writeInt(value);
	}

	/**
	 * Writes a UTF-8 string to the file stream, byte stream, or byte array. The length of
	 * the UTF-8 string in bytes is written first, as a 16-bit integer, followed by the bytes
	 * representing the characters of the string.
	 * @param		value The string value to be written.
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		RangeError — If the length of the string is larger than 65535.
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeUTF(value:String):Void {
		__checkIfWritable();

		var bytes:Bytes = crossbyte._internal.Utf8.bytesOf(value);

		if (bytes.length > 0xFFFF) {
			throw new RangeError('writeUTF takes at most 65535 bytes, and this string is ${bytes.length}. Use writeUTFBytes with a length of your own.');
		}

		if (__isAsync) {
			var segment:ByteArray = __beginAsyncWrite();
			segment.writeShort(bytes.length);
			segment.writeBytes(ByteArray.fromBytes(bytes), 0, bytes.length);
			__endAsyncWrite(segment);
			return;
		}

		// Unsigned: the prefix is a 16-bit length, and writeInt16 refused
		// anything from 32768 up with an Overflow the documentation does not
		// mention -- where ByteArray took the same string.
		__put16(bytes.length);
		__writeScratch(2);
		__output.writeFullBytes(bytes, 0, bytes.length);
	}

	/**
	 * Writes a UTF-8 string. Similar to writeUTF(), but does not prefix the string with a 16-bit length
	 * integer.
	 *
	 * @param		value The string value to be written.
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeUTFBytes(value:String):Void {
		__checkIfWritable();

		var bytes:Bytes = crossbyte._internal.Utf8.bytesOf(value);

		if (__isAsync) {
			var segment:ByteArray = __beginAsyncWrite();
			segment.writeBytes(ByteArray.fromBytes(bytes), 0, bytes.length);
			__endAsyncWrite(segment);
			return;
		}

		__output.writeFullBytes(bytes, 0, bytes.length);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
	}

	@:noCompletion private function __checkIfOpen():Void {
		if (!__isOpen) {
			throw new IOError("This FileStream object does not have a stream opened.");
		}
	}

	@:noCompletion private function __checkIfReadable():Void {
		__checkIfOpen();

		if (__isAsync) {
			if (__async.buffer == null) {
				throw new IOError("This FileStream is open to write; it has nothing to read.");
			}
			return;
		}

		if (__input == null) {
			throw new IOError("This FileStream is open to write; it has nothing to read.");
		}

		if (__output != null) {
			// The two handles of an UPDATE stream: what the writer holds back
			// is not in the file for the reader to see until it is flushed.
			__output.flush();
			__input.seek(__getSynchronousPosition(), FileSeek.SeekBegin);
		}
	}

	@:noCompletion private function __checkIfWritable():Void {
		__checkIfOpen();

		if (__isAsync) {
			if (__fileMode == READ) {
				throw new IOError("This FileStream is open to read; it cannot write.");
			}
			return;
		}

		if (__output == null) {
			throw new IOError("This FileStream is open to read; it cannot write.");
		}

		if (__fileMode == APPEND) {
			// O_APPEND semantics: writes always go to the end regardless of
			// position. cpp's native append handle enforces this; targets with
			// a seekable append handle (e.g. jvm) would otherwise honor a prior
			// seek and overwrite, so seek to the end explicitly before writing.
			__output.seek(0, FileSeek.SeekEnd);
		} else if (__input != null) {
			__output.seek(__getSynchronousPosition(), FileSeek.SeekBegin);
		}
	}

	/**
		`count` bytes from the file into the scratch buffer, or an EOFError
		with nothing consumed. haxe.io.Eof escaped every read before: the
		documented error was never thrown, and what a short read had taken
		stayed taken.
	**/
	@:noCompletion private function __take(count:Int):Bytes {
		var read:Int = __readFully(__scratch, 0, count);
		__positionDirty = true;

		if (read < count) {
			if (read > 0) {
				__input.seek(-read, FileSeek.SeekCur);
			}
			throw new EOFError('Asked for $count bytes with $read left in the file.');
		}

		return __scratch;
	}

	/** As much of `count` bytes as the file has, into `bytes`; how many. **/
	@:noCompletion private function __readFully(bytes:Bytes, offset:Int, count:Int):Int {
		var read:Int = 0;
		__positionDirty = true;

		while (read < count) {
			var got:Int = 0;

			try {
				got = __input.readBytes(bytes, offset + read, count - read);
			} catch (_:haxe.io.Eof) {
				break;
			}

			if (got <= 0) {
				break;
			}

			read += got;
		}

		return read;
	}

	@:noCompletion private inline function __u16(bytes:Bytes):Int {
		return __endian == LITTLE_ENDIAN ? (bytes.get(0) | (bytes.get(1) << 8)) : ((bytes.get(0) << 8) | bytes.get(1));
	}

	@:noCompletion private inline function __i32(bytes:Bytes, at:Int):Int {
		return __endian == LITTLE_ENDIAN ? bytes.getInt32(at) : ((bytes.get(at) << 24) | (bytes.get(at + 1) << 16) | (bytes.get(at + 2) << 8)
			| bytes.get(at + 3));
	}

	@:noCompletion private inline function __put16(value:Int):Void {
		if (__endian == LITTLE_ENDIAN) {
			__scratch.set(0, value);
			__scratch.set(1, value >> 8);
		} else {
			__scratch.set(0, value >> 8);
			__scratch.set(1, value);
		}
	}

	@:noCompletion private inline function __put32(at:Int, value:Int):Void {
		if (__endian == LITTLE_ENDIAN) {
			__scratch.setInt32(at, value);
		} else {
			__scratch.set(at, value >>> 24);
			__scratch.set(at + 1, value >> 16);
			__scratch.set(at + 2, value >> 8);
			__scratch.set(at + 3, value);
		}
	}

	@:noCompletion private inline function __writeScratch(count:Int):Void {
		__output.writeFullBytes(__scratch, 0, count);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
	}

	/** The read buffer, under its lock; the caller releases it. **/
	@:noCompletion private inline function __lockReadBuffer():ByteArray {
		var session:AsyncFile = __async;
		session.mutex.acquire();
		var buffer:ByteArray = session.buffer;
		buffer.endian = __endian;
		return buffer;
	}

	/**
		The segment the next asynchronous write goes into, at the stream's
		position, under the session's lock; `__endAsyncWrite` releases it.
		Writes at consecutive positions share a segment. They were written
		into one buffer that only grew, from wherever the writer had reached,
		so a write after moving the position went nowhere.
	**/
	@:noCompletion private function __beginAsyncWrite():ByteArray {
		var session:AsyncFile = __async;
		session.mutex.acquire();
		var segment:ByteArray = session.segmentForWrite();
		segment.endian = __endian;
		__segmentStart = segment.length;
		segment.position = segment.length;
		return segment;
	}

	@:noCompletion private function __endAsyncWrite(segment:ByteArray):Void {
		var session:AsyncFile = __async;
		session.wrote(segment, __segmentStart, segment.length - __segmentStart);
		session.mutex.release();
		isWriting = true;
	}

	@:noCompletion private function __getStreamBytesAvailable():Int {
		if (__input != null && __output != null) {
			var pos = __getSynchronousPosition();
			__output.seek(0, FileSeek.SeekEnd);
			var length = __output.tell();
			__output.seek(pos, FileSeek.SeekBegin);
			__input.seek(pos, FileSeek.SeekBegin);
			return length - pos;
		}

		if (__output != null) {
			var pos:Int = __output.tell();
			__output.seek(0, FileSeek.SeekEnd);
			var length = __output.tell();
			__output.seek(pos, FileSeek.SeekBegin);
			return length - pos;
		}

		var pos:Int = __input.tell();
		__input.seek(0, FileSeek.SeekEnd);
		var length = __input.tell();
		__input.seek(pos, FileSeek.SeekBegin);
		return length - pos;
	}

	@:noCompletion private function __getSynchronousPosition():Int {
		if (__input != null && __output != null) {
			return Std.int(Math.max(__input.tell(), __output.tell()));
		}

		if (__output != null) {
			return __output.tell();
		}

		if (__input != null) {
			return __input.tell();
		}

		return position;
	}

	@:noCompletion private function __openSync():Void {
		var path:String = __file.nativePath;

		try {
			switch (__fileMode) {
				case READ:
					__input = HaxeFile.read(path, true);
				case WRITE:
					var dirPath:String = Path.directory(path);
					if (dirPath != "" && !FileSystem.exists(dirPath)) {
						FileSystem.createDirectory(dirPath);
					}
					__output = HaxeFile.write(path, true);
				case APPEND:
					__output = HaxeFile.append(path, true);
					__output.seek(0, FileSeek.SeekEnd);
				case UPDATE:
					__output = HaxeFile.update(path, true);
					__output.seek(0, FileSeek.SeekBegin);
					__input = HaxeFile.read(path, true);
			}
		} catch (e:Dynamic) {
			__releaseSync();
			throw new IOError('Could not open "$path" to ${Std.string(__fileMode)}: ${__describe(e)}');
		}

		__isOpen = true;
		__isAsync = false;
		position = __fileMode == APPEND ? __output.tell() : 0;
		__positionDirty = false;
	}

	/**
		Dispatches an ioError after this call returns, on the runtime's
		thread; false if there is no runtime here to do it.
	**/
	@:noCompletion private function __postIoError(text:String, id:Int):Bool {
		try {
			return CrossByte.current().post(() -> dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, text, id)));
		} catch (_:Dynamic) {
			return false;
		}
	}

	@:noCompletion private static function __describe(e:Dynamic):String {
		if (Std.isOfType(e, Error)) {
			return (e : Error).message;
		}
		return Std.string(e);
	}

	@:noCompletion private function get_endian():Endian {
		return __endian;
	}

	@:noCompletion private function set_endian(value:Endian):Endian {
		// A field: set before open() it was lost, open() setting big-endian on
		// the handles regardless, and read before open() it was a null access
		// on the handle it asked. The asynchronous buffer never saw it at all.
		return __endian = value;
	}

	@:noCompletion private function set_readAhead(value:Float):Float {
		var session:Null<AsyncFile> = __async;

		if (session != null) {
			session.mutex.acquire();
			session.readAhead = value;
			session.mutex.release();
		}

		return readAhead = value;
	}

	@:noCompletion private function get_bytesAvailable():Int {
		if (!__isOpen) {
			return 0;
		}

		if (!__isAsync) {
			return __input == null ? 0 : __getStreamBytesAvailable();
		}

		var session:AsyncFile = __async;

		if (session.buffer == null) {
			return 0;
		}

		session.mutex.acquire();
		var available:Int = session.buffer.bytesAvailable;
		session.mutex.release();
		return available;
	}

	@:noCompletion private function get_position():UInt {
		if (!__isOpen) {
			return position;
		}

		if (!__isAsync) {
			if (__positionDirty) {
				__positionDirty = false;
				position = __getSynchronousPosition();
			}
			return position;
		}

		var session:AsyncFile = __async;
		session.mutex.acquire();
		var at:Int = session.position();
		session.mutex.release();
		return position = at;
	}

	@:noCompletion private function set_position(value:UInt):UInt {
		if (__isOpen) {
			if (!__isAsync) {
				if (__output != null) {
					__output.seek(value, FileSeek.SeekBegin);
				}
				if (__input != null) {
					__input.seek(value, FileSeek.SeekBegin);
				}
				__positionDirty = false;
			} else {
				var session:AsyncFile = __async;
				session.mutex.acquire();
				var restart:Bool = session.seek(value);
				session.mutex.release();

				if (restart) {
					__restartLoader(session);
				}
			}
		}

		return position = value;
	}
}

/** What an asynchronous file's worker reports, delivered on the runtime's thread. **/
@:noCompletion
private enum AsyncNotice {
	Read(loaded:Int, total:Int);
	Wrote(pending:Float, total:Float);
	Loaded;
	Failed(text:String);
	// The worker has stopped; true when it read to the end of the file.
	Finished(loadedToEnd:Bool);
}

/** Bytes waiting to be written at `at` -- `-1` at the end -- or, with `truncate`, a cut there. **/
@:noCompletion
private class AsyncWrite {
	public final at:Int;
	public final data:Null<ByteArray>;
	public final truncate:Bool;

	public function new(at:Int, data:Null<ByteArray>, truncate:Bool) {
		this.at = at;
		this.data = data;
		this.truncate = truncate;
	}
}

/**
	One asynchronously opened file: its handles, its read buffer, the writes
	waiting to reach it, and the work its worker does on both.

	The stream's thread reads and writes the buffers under `mutex`; the worker
	moves bytes between them and the file. Everything the worker touches is
	here, so a stream reopened while its last worker is still finishing hands
	that worker nothing of the new file.
**/
@:noCompletion
@:access(crossbyte.io.ByteArrayData)
@:access(crossbyte.io.File)
private class AsyncFile {
	public final mutex:Mutex = new Mutex();
	public final file:File;
	public final path:String;
	public final mode:FileMode;
	public var worker:Null<Worker>;
	public var input:Null<FileInput>;
	public var output:Null<FileOutput>;
	public var endian:Endian;
	public var readAhead:Float;
	public var pageSize:Int;

	// Reading (READ, UPDATE). The buffer holds the file from bufferStart on;
	// a position outside it bumps generation, which tells the loader to start
	// again from there. loaded says it has reached the end.
	public var buffer:Null<ByteArray>;
	public var bufferStart:Int = 0;
	public var generation:Int = 0;
	public var loaded:Bool = false;
	public var fileSize:Int = 0;
	public var reloadPending:Bool = false;

	// Writing (WRITE, APPEND, UPDATE).
	public var writes:Array<AsyncWrite> = [];
	public var pending:Int = 0;
	public var written:Float = 0;
	// Where the next write goes in WRITE and APPEND, which have no read
	// buffer to keep the position in.
	public var cursor:Int = 0;

	public var closing:Bool = false;
	public var abandoned:Bool = false;
	@:noCompletion private var __finished:Bool = false;

	public function new(file:File, mode:FileMode, endian:Endian, readAhead:Float, pageSize:Int) {
		this.file = file;
		this.path = file.nativePath;
		this.mode = mode;
		this.endian = endian;
		this.readAhead = readAhead;
		this.pageSize = pageSize;
	}

	public function openHandles():Void {
		switch (mode) {
			case READ:
				input = HaxeFile.read(path, true);
			case WRITE:
				var directory:String = Path.directory(path);
				if (directory != "" && !FileSystem.exists(directory)) {
					FileSystem.createDirectory(directory);
				}
				output = HaxeFile.write(path, true);
			case APPEND:
				output = HaxeFile.append(path, true);
				output.seek(0, FileSeek.SeekEnd);
				cursor = output.tell();
			case UPDATE:
				// Read as READ reads, as documented: the writer alone was opened,
				// so an UPDATE stream read nothing, and every read threw.
				output = HaxeFile.update(path, true);
				input = HaxeFile.read(path, true);
		}

		if (input != null) {
			buffer = new ByteArray();
			buffer.endian = endian;
			// Grows as data arrives. It was allocated at the file's full size
			// up front, so bytesAvailable counted bytes nobody had read from
			// disk yet, and reading "what is available" from a progress
			// handler -- as this class's own documentation says to --
			// returned zeros: 6.4 MB of them from a 10 MB file.
			//
			// Measured now, from a File of its own: the stream's File may be
			// holding sizes from before the file was last written.
			fileSize = new File(path).size;
		}
	}

	public function releaseHandles():Void {
		mutex.acquire();
		var reader:Null<FileInput> = input;
		var writer:Null<FileOutput> = output;
		input = null;
		output = null;
		mutex.release();

		if (writer != null) {
			try {
				writer.close();
			} catch (_:Dynamic) {}
		}

		if (reader != null) {
			try {
				reader.close();
			} catch (_:Dynamic) {}
		}
	}

	public function isFinished():Bool {
		mutex.acquire();
		var finished:Bool = __finished;
		mutex.release();
		return finished;
	}

	/** The stream's position. Held under the lock. **/
	public function position():Int {
		return buffer != null ? bufferStart + buffer.position : cursor;
	}

	/**
		Moves the stream's position, and when that is outside what the read
		buffer holds, starts reading from there instead. Held under the lock;
		returns whether the worker has to be started again because it had
		already finished.
	**/
	public function seek(value:Int):Bool {
		if (buffer == null) {
			cursor = value;
			return false;
		}

		var offset:Int = value - bufferStart;

		if (offset >= 0 && offset <= buffer.length) {
			buffer.position = offset;
			return false;
		}

		buffer.length = 0;
		buffer.position = 0;
		bufferStart = value;
		generation++;

		var restart:Bool = loaded && mode == READ;
		loaded = false;
		return restart;
	}

	/**
		The segment a write at the position goes into: the last one, when the
		write carries straight on from it. Held under the lock.
	**/
	public function segmentForWrite():ByteArray {
		var at:Int = mode == APPEND ? -1 : position();
		var last:Null<AsyncWrite> = writes.length > 0 ? writes[writes.length - 1] : null;

		if (last != null && !last.truncate) {
			if (at < 0 ? last.at < 0 : (last.at >= 0 && last.at + last.data.length == at)) {
				return last.data;
			}
		}

		var write:AsyncWrite = new AsyncWrite(at, new ByteArray(), false);
		writes.push(write);
		return write.data;
	}

	/**
		Accounts for `count` bytes just written at `start` in `segment`, and in
		UPDATE puts them in the read buffer too, at the position: what is read
		back is what was written. Held under the lock.
	**/
	public function wrote(segment:ByteArray, start:Int, count:Int):Void {
		pending += count;

		if (buffer != null) {
			buffer.writeBytes(segment, start, count);
		} else {
			cursor += count;
		}
	}

	/** Queues a cut at `at`, after whatever is pending. **/
	public function truncate(at:Int):Void {
		mutex.acquire();
		writes.push(new AsyncWrite(at, null, true));

		if (buffer != null) {
			if (at - bufferStart < buffer.length) {
				buffer.length = at - bufferStart < 0 ? 0 : at - bufferStart;
			}
			if (fileSize > at) {
				fileSize = at;
			}
		}
		mutex.release();
	}

	/**
		The worker: writes what is pending, reads ahead of the reader, and
		reports both, until the stream closes -- or, for a file opened only to
		read, until it reaches the end, after which a seek outside the buffer
		starts it again.
	**/
	public function run(_:Dynamic):Void {
		try {
			__work();
		} catch (e:Dynamic) {
			// Whoever waits for this to stop is not left waiting; the Worker
			// reports what was thrown.
			mutex.acquire();
			__finished = true;
			mutex.release();
			throw e;
		}
	}

	// Not __run: hxcpp gives every object a __run of its own.
	private function __work():Void {
		var lastGeneration:Int = -1;

		while (true) {
			mutex.acquire();
			var batch:Null<Array<AsyncWrite>> = null;
			if (writes.length > 0) {
				batch = writes;
				writes = [];
			}
			var stopping:Bool = closing || abandoned;
			var quiet:Bool = abandoned;
			mutex.release();

			if (batch != null) {
				var failure:Null<String> = __flush(batch);
				var count:Int = 0;
				for (write in batch) {
					if (write.data != null) {
						count += write.data.length;
					}
				}

				mutex.acquire();
				pending -= count;
				written += count;
				var stillPending:Float = pending;
				var total:Float = written + pending;
				mutex.release();

				if (!quiet) {
					__send(failure != null ? Failed(failure) : Wrote(stillPending, total));
				}
				continue;
			}

			if (stopping) {
				releaseHandles();
				__finish(false);
				return;
			}

			if (buffer != null) {
				switch (__loadStep(lastGeneration)) {
					case Moved(generation):
						lastGeneration = generation;
						continue;
					case Added(generation, loadedTo, total):
						lastGeneration = generation;
						__send(Read(loadedTo, total));
						continue;
					case End:
						if (mode == READ) {
							__finish(true);
							return;
						}
						__send(Loaded);
					case Broken(text):
						__send(Failed(text));
						if (mode == READ) {
							__finish(false);
							return;
						}
					case Idle | Waiting:
				}
			}

			crossbyte._internal.system.Sleep.sleep(0.001);
		}
	}

	/** One step of reading the file into the buffer. **/
	private function __loadStep(lastGeneration:Int):LoadStep {
		mutex.acquire();

		if (buffer == null || loaded) {
			mutex.release();
			return Idle;
		}

		var generation:Int = this.generation;
		var reposition:Bool = generation != lastGeneration;
		var next:Int = bufferStart + buffer.length;
		var remaining:Int = fileSize - next;
		var want:Int = remaining < pageSize ? remaining : pageSize;

		#if target.threaded
		if (readAhead != Math.POSITIVE_INFINITY) {
			var unread:Int = buffer.length - buffer.position;
			// Up to readAhead, in whole 4 KB pages, and nothing while the
			// reader has that much waiting already.
			var room:Float = readAhead - unread;
			want = room <= 0 ? 0 : Std.int(Math.min(want, Math.ceil(room / 4096) * 4096));
		}
		#end

		if (remaining <= 0) {
			loaded = true;
			mutex.release();
			return End;
		}

		var reader:Null<FileInput> = input;
		mutex.release();

		if (want <= 0 || reader == null) {
			return Waiting;
		}

		if (chunkBytes == null || chunkBytes.length < want) {
			chunkBytes = Bytes.alloc(want);
		}

		var got:Int = 0;

		try {
			// Always from where the read belongs: in UPDATE the writer may have
			// changed what the reader's own buffer last saw, and a seek drops it.
			reader.seek(next, FileSeek.SeekBegin);

			while (got < want) {
				var read:Int = 0;

				try {
					read = reader.readBytes(chunkBytes, got, want - got);
				} catch (_:haxe.io.Eof) {
					break;
				}

				if (read <= 0) {
					break;
				}

				got += read;
			}
		} catch (e:Dynamic) {
			return Broken("The file could not be read: " + Std.string(e));
		}

		mutex.acquire();

		if (buffer == null || generation != this.generation) {
			// The reader moved while this was being read; start again.
			mutex.release();
			return Moved(generation);
		}

		if (got <= 0) {
			// Shorter than it was when opened.
			loaded = true;
			mutex.release();
			return End;
		}

		// Writes may have carried the buffer past `next` while this was read,
		// and a truncate may have cut the file short of it: what they cover
		// is theirs.
		var end:Int = bufferStart + buffer.length;
		var skip:Int = end - next;
		var limit:Int = fileSize - next < got ? fileSize - next : got;

		if (skip < limit) {
			__discardConsumed();
			var cursor:Int = buffer.position;
			buffer.position = buffer.length;
			buffer.writeBytes(ByteArray.fromBytes(chunkBytes), skip, limit - skip);
			buffer.position = cursor;
		}

		var loadedTo:Int = bufferStart + buffer.length;
		var total:Int = fileSize > loadedTo ? fileSize : loadedTo;
		mutex.release();

		return Added(generation, loadedTo, total);
	}

	// The worker's read scratch, kept between steps.
	private var chunkBytes:Null<Bytes>;

	/**
		Drops what the reader has consumed, when `readAhead` bounds the buffer.
		By default it does not -- the whole file is kept, as it always was, so a
		stream can seek back without reading anything again. Held under the
		lock.
	**/
	private function __discardConsumed():Void {
		if (readAhead == Math.POSITIVE_INFINITY) {
			return;
		}

		var consumed:Int = buffer.position;

		// Half the buffer or more, so the move is paid for by what it frees.
		if (consumed == 0 || consumed < buffer.length - consumed) {
			return;
		}

		var unread:Int = buffer.length - consumed;
		var data:Bytes = buffer;

		if (unread > 0) {
			data.blit(0, data, consumed, unread);
		}

		buffer.length = unread;
		buffer.position = 0;
		bufferStart += consumed;
	}

	/** Writes `batch` to the file in order; why not, or null. **/
	private function __flush(batch:Array<AsyncWrite>):Null<String> {
		var writer:Null<FileOutput> = output;

		if (writer == null) {
			return "The file is closed.";
		}

		try {
			for (write in batch) {
				if (write.truncate) {
					writer.flush();
					FileOps.truncate(path, write.at);
				} else {
					if (write.at < 0) {
						// APPEND: the end, whatever the handle would honor.
						writer.seek(0, FileSeek.SeekEnd);
					} else {
						writer.seek(write.at, FileSeek.SeekBegin);
					}
					writer.writeFullBytes(write.data, 0, write.data.length);
				}
			}

			writer.flush();
			file.__fileStatsDirty = true;
			return null;
		} catch (e:Dynamic) {
			return "The file could not be written: " + Std.string(e);
		}
	}

	private function __send(notice:AsyncNotice):Void {
		var current:Null<Worker> = worker;
		if (current != null) {
			current.sendProgress(notice);
		}
	}

	private function __finish(loadedToEnd:Bool):Void {
		mutex.acquire();
		__finished = true;
		mutex.release();

		var current:Null<Worker> = worker;
		if (current != null) {
			current.sendComplete(Finished(loadedToEnd));
		}
	}
}

/** What one step of loading did. **/
@:noCompletion
private enum LoadStep {
	// Nothing to read: loaded already, or no read buffer.
	Idle;
	// Not now: the reader has readAhead waiting already.
	Waiting;
	// Read into the buffer, which now reaches `loadedTo` of `total`.
	Added(generation:Int, loadedTo:Int, total:Int);
	// The reader moved while this read; start again from there.
	Moved(generation:Int);
	// The end of the file.
	End;
	Broken(text:String);
}
#end
