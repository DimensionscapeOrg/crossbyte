package crossbyte.io;

// Not built for the browser. This is a synchronous, seekable handle on an open file, and a browser has no such thing, its storage APIs are asynchronous and are not addressed by byte offset. crossbyte.io.File keeps its type there and refuses the operation instead; see NoFileSystem.
#if !(js && !nodejs)

import crossbyte.events.ThreadEvent;
import haxe.Json;
import haxe.Serializer;
import haxe.Timer;
import haxe.Unserializer;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import haxe.io.Encoding;
import haxe.io.Bytes;
import haxe.io.Path;
import crossbyte.sys.Worker;
import crossbyte.errors.Error;
import crossbyte.errors.EOFError;
import crossbyte.errors.RangeError;
import crossbyte.events.Event;
import crossbyte.events.EventDispatcher;
import crossbyte.io.FileMode;
import crossbyte.errors.IOError;
import crossbyte.errors.IllegalOperationError;
import crossbyte.events.IOErrorEvent;
import crossbyte.net.ObjectEncoding;
import crossbyte.events.OutputProgressEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.io.ByteArray;
import crossbyte.io.Endian;
import crossbyte.io.IDataInput;
import crossbyte.io.IDataOutput;
import crossbyte.Object;
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
	**/
	public var endian(get, set):Endian;

	/**
		Specifies whether the HXSF, JSON, AMF3 or AMF0 format is used when writing or reading binary
		data by using the readObject() or writeObject() method.

		The value is a constant from the ObjectEncoding class. `HXSF` is the default and `JSON`
		is always available. `AMF0` and `AMF3` are read and written only when the optional
		`format` haxelib is on the build, `-lib format`. Asking for one this build cannot do
		throws, rather than reading `null` or writing nothing.

	**/
	public var objectEncoding:ObjectEncoding;

	/**
		The current position in the file.

		This value is modified in any of the following ways:

		* When you set the property explicitly
		* When reading from the FileStream object (by using one of the read methods)
		* When writing to the FileStream object

		The position is defined as a Number (instead of uint) in order to support files larger than
		232 bytes in length. The value of this property is always a whole number less than 253. If
		you set this value to a number with a fractional component, the value is rounded down to
		the nearest integer.

		When reading a file asyncronously, if you set the position property, the application begins
		filling the read buffer with the data starting at the specified position, and the bytesAvailable
		property may be set to 0. Wait for a complete event before using a read method to read data;
		or wait for a progress event and check the bytesAvailable property before using a read method.
	**/
	@:isVar public var position(get, set):UInt;

	/**
		The minimum amount of data to read from disk when reading files asynchronously.

		This property specifies how much data an asynchronous stream attempts to read beyond the current
		position. Data is read in blocks based on the file system page size. Thus if you set readAhead to
		9,000 on a computer system with an 8KB (8192 byte) page size, the runtime reads ahead 2 blocks,
		or 16384 bytes at a time. The default value of this property is infinity: by default a file that
		is opened to read asynchronously reads as far as the end of the file.

		Reading data from the read buffer does not change the value of the readAhead property. When you
		read data from the buffer, new data is read in to refill the read buffer.

		The readAhead property has no effect on a file that is opened synchronously.

		As data is read in asynchronously, the FileStream object dispatches progress events. In the event
		handler method for the progress event, check to see that the required number of bytes is available
		(by checking the bytesAvailable property), and then read the data from the read buffer by using a
		read method.
	**/
	public var readAhead:Float = Math.POSITIVE_INFINITY;

	/**
		The isWriting property returns a bool used to identify the write state of asynchronous Update,
		Append, or Write streams. If isWrite is true, data is actively being written from the buffer.
	**/
	public var isWriting(default, null):Bool = false;

	@:noCompletion private var __input:FileInput;
	@:noCompletion private var __output:FileOutput;
	@:noCompletion private var __fileMode:FileMode;
	@:noCompletion private var __file:File;
	@:noCompletion private var __fileStreamWorker:Worker;
	@:noCompletion private var __isOpen:Bool;
	@:noCompletion private var __isWrite:Bool;
	@:noCompletion private var __isAsync:Bool;
	@:noCompletion private var __pendingClose:Bool;
	// TODO:
	// Find another way to handle the situation where writeBytes has zero length during WRITE async mode.
	@:noCompletion private var __isZeroLength:Bool = false;
	@:noCompletion private var __positionDirty:Bool = false;
	@:noCompletion private var __buffer:ByteArray;
	@:noCompletion private var __fileStreamMutex:Mutex;
	@:noCompletion private var __pageSize:Int = 4096000;
	// Asynchronous reading. The buffer holds the file from __bufferStart on;
	// a position outside it bumps __loadGeneration, which tells the loader to
	// start again from there. __loaded says it has reached the end.
	@:noCompletion private var __bufferStart:Int = 0;
	@:noCompletion private var __loadGeneration:Int = 0;
	@:noCompletion private var __loaded:Bool = false;
	@:noCompletion private var __reloadPending:Bool = false;
	@:noCompletion private var __loaderWork:Dynamic->Void;

	/**
		Creates a FileStream object. Use the open() or openAsync() method to open a file.
	**/
	public function new() {
		super();
		__isOpen = false;
		isWriting = false;
		__pendingClose = false;

		objectEncoding = HXSF;
		position = 0;
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

		@event close    			The file, which was opened asynchronously, is closed.
	**/
	public function close():Void {
		if (!__isOpen || __pendingClose) {
			return;
		}

		var async = __isAsync;
		if (async) {
			__fileStreamMutex.acquire();
			// Only defer the close to the worker if it is still actively
			// running. If the worker has already finished (completed or
			// canceled) there will be no further worker event to honor
			// __pendingClose, so we must close the handle here to avoid
			// leaking it.
			if (__fileStreamWorker != null && __fileStreamWorker.running && !__fileStreamWorker.canceled) {
				__pendingClose = true;
				__fileStreamMutex.release();
				return;
			}
		}

		__isOpen = false;
		__isAsync = false;
		__pendingClose = false;
		__buffer = null;

		if (__output != null) {
			__output.close();
			__output = null;
		}

		if (__input != null) {
			__input.close();
			__input = null;
		}

		if (async) {
			__fileStreamMutex.release();
		}

		position = 0;
		__positionDirty = false;

		if (__fileStreamWorker != null) {
			__disposeFileStreamWorker();
			dispatchEvent(new Event(Event.CLOSE));
		}
	}

	/**
		 Opens the FileStream object synchronously, pointing to the file specified by the
		 file parameter.

		If the FileStream object is already open, calling the method closes the file before
		opening and no further events (including close) are delivered for the previously opened
		file.

		On systems that support file locking, a file opened in "write" or "update" mode
		(FileMode.WRITE or FileMode.UPDATE) is not readable until it is closed.

		Once you are done performing operations on the file, call the close() method of the
		FileStream object. Some operating systems limit the number of concurrently open files.
		@param 		file The File object specifying the file to open.
		@param 		 A string from the FileMode class that defines the capabilities of the
		FileStream, such as the ability to read from or write to the file.
		@throws 	IOError The file does not exist; you do not have adequate permissions to
		open the file; you are opening a file for read access, and you do not have read
		permissions; or you are opening a file for write access, and you do not have write
		permissions.
		@throws 	SecurityError The file location is in the application directory, and the
		fileMode parameter is set to "append", "update", or "write" mode.
	 */
	public function open(file:File, fileMode:FileMode):Void {
		__file = file;
		__fileMode = fileMode;

		__openFile();
	}

	@:noCompletion private function __disposeFileStreamWorker():Void {
		if (__fileStreamWorker == null) {
			return;
		}

		__fileStreamWorker.removeEventListener(ThreadEvent.COMPLETE, __onFileStreamWorkerComplete);
		__fileStreamWorker.removeEventListener(ThreadEvent.ERROR, __onFileStreamWorkerError);
		__fileStreamWorker.removeEventListener(ThreadEvent.PROGRESS, __onFileStreamWorkerProgress);

		__fileStreamWorker.cancel();
		__fileStreamWorker = null;
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
		or FileMode.UPDATE) is not readable until it is closed.

		Once you are done performing operations on the file, call the close() method of the FileStream
		object. Some operating systems limit the number of concurrently open files.

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
		@throws 	SecurityError The file location is in the application directory, and the
		fileMode parameter is set to "append", "update", or "write" mode.
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

		__isAsync = true;

		__fileStreamMutex = new Mutex();

		__fileStreamWorker = new Worker();
		__fileStreamWorker.addEventListener(ThreadEvent.COMPLETE, __onFileStreamWorkerComplete);
		__fileStreamWorker.addEventListener(ThreadEvent.ERROR, __onFileStreamWorkerError);
		__fileStreamWorker.addEventListener(ThreadEvent.PROGRESS, __onFileStreamWorkerProgress);

		open(file, fileMode);

		if (fileMode == READ) {
			// Grows as data arrives. It was allocated at the file's full size
			// up front, so bytesAvailable counted bytes nobody had read from
			// disk yet, and reading "what is available" from a progress handler,
			// as this class's own documentation says to, returned zeros:
			// 6.4 MB of them from a 10 MB file. The whole file also stayed in
			// memory whatever readAhead said.
			__buffer = new ByteArray();
			__bufferStart = 0;
			__loadGeneration = 0;
			__loaded = false;

			var fileSize:Int = file.size;

			__loaderWork = function(m:Dynamic) {
				__loadAsync(fileSize);
			};
			__fileStreamWorker.doWork = __loaderWork;
		} else {
			__buffer = new ByteArray();

			__fileStreamWorker.doWork = function(m:Dynamic) {
				var bytesLoaded:Int = 0;

				while (__fileStreamWorker != null) {
					Sys.sleep(.001);

					__fileStreamMutex.acquire();
					while (isWriting) {
						while (__buffer.length > bytesLoaded || __isZeroLength) {
							try {
								var maxBytes:Int = Std.int(Math.min(__pageSize, __buffer.length - bytesLoaded));

								__output.writeBytes(__buffer, bytesLoaded, maxBytes);
								bytesLoaded += maxBytes;

								__file.__fileStatsDirty = true;
								__isZeroLength = false;

								__fileStreamWorker.sendProgress(new OutputProgressEvent(OutputProgressEvent.OUTPUT_PROGRESS, __buffer.length - bytesLoaded,
									__buffer.length));
							} catch (e:Dynamic) {
								__fileStreamWorker.sendError(new IOErrorEvent(IOErrorEvent.IO_ERROR, "Index is out of bounds."));
								break;
							}
						}

						isWriting = false;
					}
					__fileStreamMutex.release();
					if (__pendingClose) {
						// close() was called
						__fileStreamWorker.sendComplete();
						return;
					}
				}
			}
		}

		__fileStreamWorker.run();
	}

	/**
	 * Loads an asynchronously opened file into the read buffer, on the
	 * stream's worker.
	 *
	 * Appends as it reads, so the buffer only ever holds what has really been
	 * read. Where the worker has a thread of its own it also waits for the
	 * reader, loading only while less than `readAhead` is waiting to be read,
	 * and a finite `readAhead` drops what has been consumed, together those
	 * bound the memory to about `readAhead`. Where the worker runs inline
	 * there is nobody to wait for, so it reads to the end, dispatching
	 * progress as it goes.
	 *
	 * A position set outside what the buffer holds starts the load again
	 * from there; `__loadGeneration` is how this learns of it.
	 */
	@:noCompletion private function __loadAsync(fileSize:Int):Void {
		var generation:Int = -1;
		var chunk:Bytes = null;

		while (true) {
			if (__pendingClose) {
				// close() was called
				__fileStreamWorker.sendComplete();
				return;
			}

			__fileStreamMutex.acquire();

			if (__buffer == null) {
				__fileStreamMutex.release();
				return;
			}

			var reposition:Bool = generation != __loadGeneration;
			generation = __loadGeneration;
			var next:Int = __bufferStart + __buffer.length;
			var remaining:Int = fileSize - next;
			var want:Int = remaining < __pageSize ? remaining : __pageSize;

			#if target.threaded
			if (readAhead != Math.POSITIVE_INFINITY) {
				var unread:Int = __buffer.length - __buffer.position;
				// Up to readAhead, in whole 4 KB pages, and nothing while the
				// reader has that much waiting already.
				var room:Float = readAhead - unread;
				want = room <= 0 ? 0 : Std.int(Math.min(want, Math.ceil(room / 4096) * 4096));
			}
			#end

			if (remaining <= 0) {
				__loaded = true;
			}

			__fileStreamMutex.release();

			if (remaining <= 0) {
				break;
			}

			if (want <= 0) {
				Sys.sleep(0.001);
				continue;
			}

			var got:Int = 0;

			try {
				if (reposition) {
					__input.seek(next, FileSeek.SeekBegin);
				}

				if (chunk == null || chunk.length < want) {
					chunk = Bytes.alloc(want);
				}

				while (got < want) {
					var read:Int = 0;

					try {
						read = __input.readBytes(chunk, got, want - got);
					} catch (_:haxe.io.Eof) {
						break;
					}

					if (read <= 0) {
						break;
					}

					got += read;
				}
			} catch (e:Dynamic) {
				__fileStreamWorker.sendError(new IOErrorEvent(IOErrorEvent.IO_ERROR, "The file could not be read: " + Std.string(e)));
				return;
			}

			if (got <= 0) {
				// Shorter than it was when opened.
				__fileStreamMutex.acquire();
				__loaded = true;
				__fileStreamMutex.release();
				break;
			}

			__fileStreamMutex.acquire();

			if (__buffer == null || generation != __loadGeneration) {
				// The reader moved while this was being read; start again.
				__fileStreamMutex.release();
				continue;
			}

			__discardConsumed();

			var cursor:Int = __buffer.position;
			__buffer.position = __buffer.length;
			__buffer.writeBytes(ByteArray.fromBytes(chunk), 0, got);
			__buffer.position = cursor;

			var loaded:Int = __bufferStart + __buffer.length;
			__fileStreamMutex.release();

			__fileStreamWorker.sendProgress(new ProgressEvent(ProgressEvent.PROGRESS, loaded, fileSize));
		}

		__fileStreamWorker.sendComplete(new Event(Event.COMPLETE));
	}

	/**
	 * Drops what the reader has consumed, when `readAhead` bounds the buffer.
	 * By default it does not, the whole file is kept, as it always was, so a
	 * stream can seek back without reading anything again. Held under the
	 * stream's mutex.
	 */
	@:noCompletion private function __discardConsumed():Void {
		if (readAhead == Math.POSITIVE_INFINITY) {
			return;
		}

		var consumed:Int = __buffer.position;

		// Half the buffer or more, so the move is paid for by what it frees.
		if (consumed == 0 || consumed < __buffer.length - consumed) {
			return;
		}

		var unread:Int = __buffer.length - consumed;
		var data:Bytes = __buffer;

		if (unread > 0) {
			data.blit(0, data, consumed, unread);
		}

		__buffer.length = unread;
		__buffer.position = 0;
		__bufferStart += consumed;
	}

	/**
	 * Moves the read position of an asynchronously opened file, and when that
	 * is outside what the buffer holds, starts loading from there instead.
	 * Held under the stream's mutex; returns whether the loader has to be
	 * started again because it had already finished.
	 */
	@:noCompletion private function __seekAsync(value:Int):Bool {
		var offset:Int = value - __bufferStart;

		if (offset >= 0 && offset <= __buffer.length) {
			__buffer.position = offset;
			return false;
		}

		__buffer.length = 0;
		__buffer.position = 0;
		__bufferStart = value;
		__loadGeneration++;

		var restart:Bool = __loaded;
		__loaded = false;
		return restart;
	}

	/**
	 * Starts the loader again after a position outside the buffer, or, while
	 * it is still finishing its last load, has its completion do so.
	 */
	@:noCompletion private function __restartLoader():Void {
		if (__fileStreamWorker == null || __loaderWork == null) {
			return;
		}

		if (__fileStreamWorker.running) {
			__reloadPending = true;
			return;
		}

		// cancel() cleared the body along with everything else.
		__fileStreamWorker.doWork = __loaderWork;
		__fileStreamWorker.run();
	}

	private function __onFileStreamWorkerComplete(e:ThreadEvent):Void {
		var event:Event = e.message;

		// close() checks the canceled property to determine if it should
		// actually close or wait for the worker to finish
		__fileStreamWorker.cancel();
		if (e != null) {
			dispatchEvent(e);
		}
		if (__pendingClose) {
			__pendingClose = false;
			close();
		} else if (__reloadPending && __fileStreamWorker != null) {
			__reloadPending = false;
			__restartLoader();
		}
	}

	private function __onFileStreamWorkerProgress(e:ThreadEvent):Void {
		var event:Event = e.message;
		dispatchEvent(event);
	}

	private function __onFileStreamWorkerError(e:ThreadEvent):Void {
		var event:Event = e.message;
		// close() checks the canceled property to determine if it should
		// actually close or wait for the worker to finish
		__fileStreamWorker.cancel();
		if (e != null) {
			dispatchEvent(e);
		}
		if (__pendingClose) {
			__pendingClose = false;
			close();
		}
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
		__positionDirty = true;
		if (__isAsync) {
			__fileStreamMutex.acquire();
			var result = __buffer.readBoolean();
			__fileStreamMutex.release();
			return result;
		}
		return __input.readByte() == 1;
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
		__positionDirty = true;

		if (__isAsync) {
			__fileStreamMutex.acquire();
			var result = __buffer.readByte();
			__fileStreamMutex.release();
			return result;
		}

		return __input.readByte();
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
			__fileStreamMutex.acquire();
			__buffer.readBytes(bytes, offset, length);
			__fileStreamMutex.release();
			__positionDirty = true;
			return;
		}

		if (length == 0) {
			__input.seek(0, FileSeek.SeekEnd);
			length = __input.tell() - position;
			__input.seek(position, FileSeek.SeekBegin);
		}

		var byteArrayData:ByteArrayData = bytes;
		if (byteArrayData.length < offset + length) {
			byteArrayData.__resize(offset + length);
		}

		// Read straight into the destination. This used to allocate a fresh
		// `Bytes` per call and copy it across, which at a 64 KB slice is
		// roughly sixteen thousand transient allocations and a second copy
		// of every byte for each gigabyte streamed.
		var read:Int = 0;

		while (read < length) {
			var got:Int = 0;

			try {
				got = __input.readBytes(byteArrayData, offset + read, length - read);
			} catch (_:haxe.io.Eof) {
				break;
			}

			if (got <= 0) {
				break;
			}

			read += got;
		}

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

			__positionDirty = true;
			throw new EOFError('Asked for $length bytes with ${read} left in the file.');
		}

		__positionDirty = true;
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
		__positionDirty = true;

		if (__isAsync) {
			__fileStreamMutex.acquire();
			var result = __buffer.readDouble();
			__fileStreamMutex.release();
			return result;
		}

		return __input.readDouble();
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
		__positionDirty = true;

		if (__isAsync) {
			__fileStreamMutex.acquire();
			var result = __buffer.readFloat();
			__fileStreamMutex.release();
			return result;
		}

		return __input.readFloat();
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
		__positionDirty = true;

		if (__isAsync) {
			__fileStreamMutex.acquire();
			var result = __buffer.readInt();
			__fileStreamMutex.release();
			return result;
		}

		return __input.readInt32();
	}

	/**
	 * Reads a multibyte string of specified length from the file stream, byte stream, or byte array using
	 * the specified character set.
	 *
	 * @param		length The number of bytes from the byte stream to read.
	 * @param		charSet The string denoting the character set to use to interpret the bytes. Possible
	 * character set strings include "shift-jis", "cn-gb", "iso-8859-1", and others.	 *
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
		__checkIfReadable();
		__positionDirty = true;

		if (__isAsync) {
			__fileStreamMutex.acquire();
			var result = __buffer.readMultiByte(length, charSet);
			__fileStreamMutex.release();
			return result;
		}

		return readUTFBytes(length);
	}

	/**
	 * Reads an object from the file stream, byte stream, or byte array, encoded in AMF serialized format.
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
			__positionDirty = true;
			__fileStreamMutex.acquire();
			var result = __buffer.readObject();
			__fileStreamMutex.release();
			return result;
		}

		switch (objectEncoding) {
			#if format
			case AMF0:
				var bytes:Bytes = Bytes.alloc(bytesAvailable);
				__input.readBytes(bytes, 0, bytesAvailable);

				var input = new BytesInput(bytes, 0);
				var reader = new AMFReader(input);
				var data = ByteArrayData.unwrapAMFValue(reader.read());
				__positionDirty = true;
				return data;

			case AMF3:
				var bytes:Bytes = Bytes.alloc(bytesAvailable);
				__input.readBytes(bytes, 0, bytesAvailable);

				var input = new BytesInput(bytes, 0);
				var reader = new AMF3Reader(input);
				var data = ByteArrayData.unwrapAMF3Value(reader.read());
				__positionDirty = true;
				return data;
			#end

			case HXSF:
				var data = readUTF();
				return Unserializer.run(data);

			case JSON:
				var data = readUTF();
				return Json.parse(data);

			default:
				throw new Error(ByteArrayData.__unsupportedEncoding(objectEncoding));
		}
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
		__positionDirty = true;

		if (__isAsync) {
			__fileStreamMutex.acquire();
			var result = __buffer.readShort();
			__fileStreamMutex.release();
			return result;
		}

		return __input.readInt16();
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
		__positionDirty = true;

		if (__isAsync) {
			__fileStreamMutex.acquire();
			var result = __buffer.readUnsignedByte();
			__fileStreamMutex.release();
			return result;
		}

		return ByteArray.fromBytes(__input.read(1)).readUnsignedByte();
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
		__positionDirty = true;

		if (__isAsync) {
			__fileStreamMutex.acquire();
			var result = __buffer.readUnsignedInt();
			__fileStreamMutex.release();
			return result;
		}

		return __input.readInt32();
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
		__positionDirty = true;

		if (__isAsync) {
			__fileStreamMutex.acquire();
			var result = __buffer.readUnsignedShort();
			__fileStreamMutex.release();
			return result;
		}

		return __input.readUInt16();
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
		__positionDirty = true;

		if (__isAsync) {
			__fileStreamMutex.acquire();
			var result = __buffer.readUTF();
			__fileStreamMutex.release();
			return result;
		}

		var length:Int = __input.readUInt16();
		return __input.readString(length);
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
		__positionDirty = true;

		if (__isAsync) {
			__fileStreamMutex.acquire();
			var result = __buffer.readUTFBytes(length);
			__fileStreamMutex.release();
			return result;
		}

		return __input.readString(length);
	}

	/**
	 * Truncates the file at the position specified by the position property of the FileStream object.
	 *
	 * Bytes from the position specified by the position property to the end of the file are deleted.
	 * The file must be open for writing.
	 * @throws 		IllegalOperationError The file is not open for writing.
	 */
	public function truncate():Void {
		__checkIfOpen();

		var targetPosition:Int = position;
		var fileMode:FileMode = __fileMode;
		var isAsync:Bool = __isAsync;
		var reopenMode = switch (fileMode) {
			case WRITE, APPEND: UPDATE;
			default: fileMode;
		}
		close();

		var fileBytes:Bytes = HaxeFile.getBytes(__file.nativePath);
		var truncatedLength = Std.int(Math.min(targetPosition, fileBytes.length));
		var truncatedBytes = Bytes.alloc(targetPosition);
		truncatedBytes.blit(0, fileBytes, 0, truncatedLength);

		HaxeFile.saveBytes(__file.nativePath, truncatedBytes);

		if (isAsync) {
			openAsync(__file, reopenMode);
		} else {
			open(__file, reopenMode);
		}
		position = targetPosition;

		__file.__fileStatsDirty = true;
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
		__checkIfWritable();

		if (__isAsync) {
			__fileStreamMutex.acquire();
			__buffer.writeBoolean(value);
			isWriting = true;
			__fileStreamMutex.release();

			return;
		}

		__output.writeByte(value ? 1 : 0);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
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
			__fileStreamMutex.acquire();
			__buffer.writeByte(value);
			isWriting = true;
			__fileStreamMutex.release();

			return;
		}

		__output.writeByte(value);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
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

		if (__isAsync) {
			__fileStreamMutex.acquire();
			__buffer.writeBytes(bytes, offset, length);

			if (length == 0)
				__isZeroLength = true;
			isWriting = true;
			__fileStreamMutex.release();

			return;
		}

		if (length == 0) {
			length = bytes.length - offset;
		}

		__output.writeBytes(bytes, offset, length);

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
			__fileStreamMutex.acquire();
			__buffer.writeDouble(value);
			isWriting = true;
			__fileStreamMutex.release();

			return;
		}

		__output.writeDouble(value);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
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
			__fileStreamMutex.acquire();
			__buffer.writeFloat(value);
			isWriting = true;
			__fileStreamMutex.release();

			return;
		}

		__output.writeFloat(value);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
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
			__fileStreamMutex.acquire();
			__buffer.writeInt(value);
			isWriting = true;
			__fileStreamMutex.release();

			return;
		}

		__output.writeInt32(value);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
	}

	/**
	 * Writes a multibyte string to the file stream, byte stream, or byte array, using the specified
	 * character set.
	 *
	 * @param		value The string value to be written.
	 * @param		charSet The string denoting the character set to use. Possible character set strings
	 * include "shift-jis", "cn-gb", "iso-8859-1", and others
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeMultiByte(value:String, charSet:String):Void {
		__checkIfWritable();

		if (__isAsync) {
			__fileStreamMutex.acquire();
			__buffer.writeMultiByte(value, charSet);
			isWriting = true;
			__fileStreamMutex.release();

			return;
		}

		writeUTFBytes(value);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
	}

	/**
	 * Writes an object to the file stream, byte stream, or byte array, in AMF, HXSF, or JSON serialized
	 * format. The optional `format` haxelib, `-lib format`, is required for AMF.
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

		if (__isAsync) {
			__fileStreamMutex.acquire();
			__buffer.writeObject(object);
			isWriting = true;
			__fileStreamMutex.release();

			return;
		}

		__writeObject(object);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
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
			__fileStreamMutex.acquire();
			__buffer.writeShort(value);
			isWriting = true;
			__fileStreamMutex.release();

			return;
		}

		__output.writeInt16(value);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
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
		__checkIfWritable();

		if (__isAsync) {
			__fileStreamMutex.acquire();
			__buffer.writeUnsignedInt(value);
			isWriting = true;
			__fileStreamMutex.release();

			return;
		}

		__output.writeInt32(value);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
	}

	/**
	 * Writes a UTF-8 string to the file stream, byte stream, or byte array. The length of
	 * the UTF-8 string in bytes is written first, as a 16-bit integer, followed by the bytes
	 * representing the characters of the string.
	 * @param		value The string value to be written.
	 * @event 		ioError  You cannot write to the file (for example, because the file is missing).
	 * This event is dispatched only for files that have been opened for asynchronous operations (by
	 * using the openAsync() method).
	 * @throws 		RangeError, If the length of the string is larger than 65535.
	 * @throws 		The file has not been opened; the file has been opened, but it was not opened
	 * with write capabilities; or for a file that has been opened for synchronous operations (by
	 * using the open() method), the file cannot be written (for example, because the file is missing).
	 */
	public function writeUTF(value:String):Void {
		__checkIfWritable();

		if (__isAsync) {
			__fileStreamMutex.acquire();

			try {
				__buffer.writeUTF(value);
			} catch (e:Dynamic) {
				__fileStreamMutex.release();
				throw e;
			}

			isWriting = true;
			__fileStreamMutex.release();

			return;
		}

		var bytes = Bytes.ofString(value);

		if (bytes.length > 0xFFFF) {
			throw new RangeError('writeUTF takes at most 65535 bytes, and this string is ${bytes.length}. Use writeUTFBytes with a length of your own.');
		}

		// Unsigned: the prefix is a 16-bit length, and writeInt16 refused
		// anything from 32768 up with an Overflow the documentation does not
		// mention, where ByteArray took the same string.
		__output.writeUInt16(bytes.length);
		__output.writeBytes(bytes, 0, bytes.length);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
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

		if (__isAsync) {
			__fileStreamMutex.acquire();
			__buffer.writeUTFBytes(value);
			isWriting = true;
			__fileStreamMutex.release();

			return;
		}

		__output.writeString(value);
		__file.__fileStatsDirty = true;
		__positionDirty = true;
	}

	@:noCompletion private function __checkIfOpen():Void {
		if (!__isOpen) {
			throw new Error("This FileStream object does not have a stream opened.", 2092);
		}
	}

	@:noCompletion private function __checkIfReadable():Void {
		__checkIfOpen();

		if (__isAsync) {
			if (__fileMode != READ) {
				throw new Error("This FileStream object does not have a input stream opened.", 2092);
			}
			return;
		}

		if (__input == null) {
			throw new Error("This FileStream object does not have a input stream opened.", 2092);
		}

		if (__output != null) {
			__input.seek(__getSynchronousPosition(), FileSeek.SeekBegin);
		}
	}

	@:noCompletion private function __checkIfWritable():Void {
		__checkIfOpen();

		if (__output == null) {
			throw new Error("This FileStream object does not have a output stream opened.", 2092);
		}

		if (!__isAsync) {
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
	}

	@:noCompletion private function __getStreamBytesAvailable():Int {
		if (!__isAsync && __input != null && __output != null) {
			var pos = __getSynchronousPosition();
			__output.seek(0, FileSeek.SeekEnd);
			var length = __output.tell();
			__output.seek(pos, FileSeek.SeekBegin);
			__input.seek(pos, FileSeek.SeekBegin);
			return length - pos;
		}

		if (__output != null && __input == null) {
			var pos:Int = position;

			if (__isAsync) {
				__fileStreamMutex.acquire();
				pos = __output.tell();
			}

			__output.seek(0, FileSeek.SeekEnd);
			var length = __output.tell();
			__output.seek(pos, FileSeek.SeekBegin);

			if (__isAsync) {
				__fileStreamMutex.release();
			}

			return length - pos;
		}

		var pos:Int = position;

		if (__isAsync) {
			__fileStreamMutex.acquire();
			pos = __input.tell();
		}

		__input.seek(0, FileSeek.SeekEnd);
		var length = __input.tell();
		__input.seek(pos, FileSeek.SeekBegin);

		if (__isAsync) {
			__fileStreamMutex.release();
		}

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

	@:noCompletion private function __openFile():Void {
		if (__isOpen) {
			if (__fileStreamWorker != null) {
				// when opening a new file, if an existing file is already open,
				// we should not dispatch Event.CLOSE, so dispose the worker
				// right away
				__disposeFileStreamWorker();
			}
			close();
		}

		__isOpen = true;

		switch (__fileMode) {
			case READ:
				try {
					__input = HaxeFile.read(__file.nativePath, true);
					__input.seek(0, FileSeek.SeekBegin);
					__isWrite = false;
				} catch (e:Dynamic) {
					throw new IOError("Invalid parameters.");
				}
			case WRITE:
				try {
					var dirPath:String = Path.directory(__file.nativePath);
					if (!FileSystem.exists(dirPath))
						FileSystem.createDirectory(dirPath);
					__output = HaxeFile.write(__file.nativePath, true);
					__isWrite = true;
				} catch (e:Dynamic) {
					throw new IOError("Invalid parameters.");
				}
			case APPEND:
				try {
					__output = HaxeFile.append(__file.nativePath, true);
					__output.seek(0, sys.io.FileSeek.SeekEnd);
					__isWrite = true;
				} catch (d:Dynamic) {
					throw new IOError("Invalid parameters.");
				}
			case UPDATE:
				try {
					__output = HaxeFile.update(__file.nativePath, true);
					__output.seek(0, sys.io.FileSeek.SeekBegin);
					if (!__isAsync) {
						__input = HaxeFile.read(__file.nativePath, true);
						__input.seek(0, FileSeek.SeekBegin);
					}
					__isWrite = true;
				} catch (d:Dynamic) {
					throw new IOError("Invalid parameters.");
				}
		}

		if (__output != null) {
			__output.bigEndian = true;
		}
		if (__input != null) {
			__input.bigEndian = true;
		}

		if (!__isAsync) {
			position = (__fileMode == APPEND) ? __file.size : __getSynchronousPosition();
			__positionDirty = false;
		}
	}

	@:noCompletion private function __writeObject(object:Dynamic):Void {
		switch (objectEncoding) {
			#if format
			case AMF0:
				var value = AMFTools.encode(object);
				var output:BytesOutput = new BytesOutput();
				var writer = new AMFWriter(output);
				writer.write(value);
				var bytes:Bytes = output.getBytes();
				__output.writeBytes(bytes, 0, bytes.length);

			case AMF3:
				var value = AMF3Tools.encode(object);
				var output = new BytesOutput();
				var writer = new AMF3Writer(output);
				writer.write(value);
				var bytes:Bytes = output.getBytes();
				__output.writeBytes(bytes, 0, bytes.length);
			#end

			case HXSF:
				var value = Serializer.run(object);
				writeUTF(value);

			case JSON:
				var value = Json.stringify(object);
				writeUTF(value);

			default:
				throw new Error(ByteArrayData.__unsupportedEncoding(objectEncoding));
		}
	}

	@:noCompletion private function get_endian():Endian {
		if (__output != null) {
			return __output.bigEndian ? BIG_ENDIAN : LITTLE_ENDIAN;
		}

		return __input.bigEndian ? BIG_ENDIAN : LITTLE_ENDIAN;
	}

	@:noCompletion private function set_endian(value:Endian):Endian {
		if (__output != null) {
			__output.bigEndian = value == BIG_ENDIAN ? true : false;
		}

		if (__input != null) {
			__input.bigEndian = value == BIG_ENDIAN ? true : false;
		}

		return value;
	}

	@:noCompletion private function get_bytesAvailable():Int {
		if (__isOpen) {
			if (!__isAsync) {
				return __getStreamBytesAvailable();
			}

			if (__fileMode == READ) {
				__fileStreamMutex.acquire();
				var result = 0;
				if (__buffer != null) {
					result = __buffer.bytesAvailable;
				}
				__fileStreamMutex.release();
				return result;
			}
		}

		return 0;
	}

	@:noCompletion private function get_position():UInt {
		if (__positionDirty) {
			if (!__isAsync) {
				__positionDirty = false;
				return position = __getSynchronousPosition();
			}
			if (__fileMode == READ) {
				__fileStreamMutex.acquire();
				// The buffer may no longer start at the start of the file.
				position = __bufferStart + __buffer.position;
				__fileStreamMutex.release();
				return position;
			}
		}
		return position;
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
			} else {
				var restart:Bool = false;
				__fileStreamMutex.acquire();

				if (__fileMode == READ) {
					restart = __seekAsync(value);
				} else {
					__buffer.position = value;
				}

				__fileStreamMutex.release();

				if (restart) {
					__restartLoader();
				}
			}
		}

		return position = value;
	}
}
#end
