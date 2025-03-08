package crossbyte.rpc;

import crossbyte.utils.ChecksumAlgorithm;
import crossbyte.utils.CompressionAlgorithm;
import crossbyte.rpc.RPCValueType;

/**
 * ...
 * @author Christopher Speciale
 */

/**
 * Defines the possible fields that can exist in an RPC header.
 * 
 * The RPC header contains metadata required for processing messages, such as
 * message identification, size, and optional features like checksums or encryption.
 * 
 * Some fields are **automatically generated**, while others require external values.
 * The `RPCHeaderFieldFactory` acts as a **blueprint** for constructing an RPC header.
 */
 enum RPCHeaderFieldFactoryType {

    /**
     * **Message ID** (Mandatory)
     * 
     * - A unique identifier for each RPC message.
     * - Used for tracking and matching responses.
     * - Typically auto-incremented or generated uniquely per message.
     */
    MessageID;

    /**
     * **Message Size** (Mandatory)
     * 
     * - Represents the **total size** of the message in bytes (header + payload).
     * - Automatically calculated when constructing the message.
     */
    MessageSize;

    /**
     * **Timestamp** (Optional)
     * 
     * - Records the **time the message was sent**.
     * - Useful for **latency measurement, debugging, and event ordering**.
     * - Typically stored as a UNIX timestamp (milliseconds since epoch).
     */
    Timestamp;

    /**
     * **Flags (Bitfield)** (Optional)
     * 
     * - Represents **8 individual boolean flags** that can be used for various purposes.
     * - When constructing the final message, these booleans are converted into a bitfield (`Int`).
     * - The first flag (`bit0`) is **required**, and the rest (`bit1` to `bit7`) are optional.
     * 
     * @param bit0 First flag (required)
     * @param bit1 Second flag (optional)
     * @param bit2 Third flag (optional)
     * @param bit3 Fourth flag (optional)
     * @param bit4 Fifth flag (optional)
     * @param bit5 Sixth flag (optional)
     * @param bit6 Seventh flag (optional)
     * @param bit7 Eighth flag (optional)
     */
    Flags(bit0:Bool, ?bit1:Bool, ?bit2:Bool, ?bit3:Bool, ?bit4:Bool, ?bit5:Bool, ?bit6:Bool, ?bit7:Bool);

    /**
     * **Checksum** (Optional)
     * 
     * - Used to verify the **integrity of the message**.
     * - Ensures that the data has not been altered or corrupted.
     * - The `type` parameter specifies the checksum algorithm to use.
     * 
     * @param type The checksum algorithm (CRC32, MD5, SHA1, etc.).
     */
    Checksum(type:ChecksumAlgorithm);

    /**
     * **Compression Type** (Optional)
     * 
     * - Specifies the **compression algorithm** used for this message (if any).
     * - This allows the system to correctly decompress the message payload.
     * - The value is dynamically generated via the `factory` function.
     * 
     * @param factory A function that provides the compression type.
     */
     CompressionType(type:CompressionAlgorithm);

    /**
     * **Session ID** (Optional)
     * 
     * - Identifies the session associated with this message.
     * - This is useful for **tracking user sessions or multi-message transactions**.
     * - The value is provided dynamically via the `factory` function.
     * 
     * @param provider A function that provides the session ID (e.g., fetching from session manager).
     */
    SessionID(?provider:Void->Int);

    /**
     * **Request ID** (Optional)
     * 
     * - Identifies an RPC **request-response pair**.
     * - Used when responses need to be matched with their original request.
     * - The value is dynamically generated via the `factory` function.
     * 
     * @param provider A function that provides the request ID.
     */
    RequestID(?provider:Void->Int);

    /**
     * **Retry Count** (Optional)
     * 
     * - Tracks the number of **retry attempts** for a message.
     * - Useful for RPC systems that **automatically retry** failed messages.
     * - The value is dynamically generated via the `factory` function.
     * 
     * @param provider A function that provides the retry count.
     */
    RetryCount(?provider:Void->Int);

    /**
     * **Encryption Mode** (Optional)
     * 
     * - Specifies the **encryption method** used for this message (if any).
     * - The value is dynamically generated via the `factory` function.
     * 
     * @param provider A function that provides the encryption mode (e.g., AES, RSA).
     */
    EncryptionMode(?provider:Void->Int);    

    /**
     * **Custom Header Field** (Optional)
     * 
     * - Allows defining a **custom, user-defined header field**.
     * - This is useful for protocol extensions that require extra metadata.
     * - The field's **data type** must be explicitly declared (`RPCValueType`).
     * 
     * @param provider A function that provides the custom field value.
     * @param type The expected data type of the custom field.
     */
    Custom(?provider:Void->Dynamic, type:RPCValueType); //TODO: Do we really need the type here? Maybe not!
}