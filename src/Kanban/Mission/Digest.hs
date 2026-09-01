-- | SHA-256, for the digest a sealed archive is verified by.
--
-- Written out rather than depended on. Kanban's dependency set is small and
-- deliberate, and the two ways to avoid this module are both worse: a new
-- cryptographic dependency for one digest, or shelling out to @shasum@ — which
-- requirement 15 of issue #592 forbids outright, since this slice spawns no
-- process at all.
--
-- The algorithm is FIPS 180-4's, and the implementation is the literal one:
-- the constants and the round function are transcribed rather than derived, so
-- the whole of it is checkable against the standard's own test vectors, which
-- is what "Spec.Mission" does.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Digest
  ( sha256Hex,
  )
where

import Data.Bits (complement, rotateR, shiftR, xor, (.&.))
import qualified Data.ByteString as ByteString
import Data.List (zipWith4)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64, Word8)
import Numeric (showHex)

-- | The lowercase hexadecimal SHA-256 of some bytes.
sha256Hex :: ByteString.ByteString -> Text
sha256Hex message = Text.concat (map hexByte (concatMap wordBytes (stateWords final)))
  where
    final = foldl' compress initialState (chunksOf 64 (message <> padding (fromIntegral (ByteString.length message))))

-- | The eight working words, kept strict so a long message does not build a
-- chain of thunks one chunk deep.
data Sha256State = Sha256State !Word32 !Word32 !Word32 !Word32 !Word32 !Word32 !Word32 !Word32

stateWords :: Sha256State -> [Word32]
stateWords (Sha256State a b c d e f g h) = [a, b, c, d, e, f, g, h]

initialState :: Sha256State
initialState =
  Sha256State
    0x6a09e667
    0xbb67ae85
    0x3c6ef372
    0xa54ff53a
    0x510e527f
    0x9b05688c
    0x1f83d9ab
    0x5be0cd19

-- | FIPS 180-4's sixty-four round constants, in order.
roundConstants :: [Word32]
roundConstants =
  [ 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ]

-- | The message padding: a single set bit, then zeroes, then the message
-- length in bits as a big-endian 64-bit word, sized so the whole message is a
-- multiple of 64 bytes.
padding :: Word64 -> ByteString.ByteString
padding messageBytes =
  ByteString.singleton 0x80
    <> ByteString.replicate zeroBytes 0
    <> ByteString.pack (bigEndian64 (messageBytes * 8))
  where
    -- The message, its one set bit, and the eight length bytes must come
    -- to a multiple of 64. Reduced before the subtraction so the arithmetic
    -- stays inside a non-negative 'Int' rather than relying on 'Word64'
    -- wrapping around to the same answer.
    zeroBytes = (55 - fromIntegral (messageBytes `mod` 64) + 64) `mod` 64

bigEndian64 :: Word64 -> [Word8]
bigEndian64 value = [fromIntegral (value `shiftR` shiftBy) | shiftBy <- [56, 48, 40, 32, 24, 16, 8, 0]]

chunksOf :: Int -> ByteString.ByteString -> [ByteString.ByteString]
chunksOf size bytes
  | ByteString.null bytes = []
  | otherwise = let (chunk, rest) = ByteString.splitAt size bytes in chunk : chunksOf size rest

-- | One sixty-four-round compression of one 64-byte block.
compress :: Sha256State -> ByteString.ByteString -> Sha256State
compress (Sha256State a0 b0 c0 d0 e0 f0 g0 h0) block =
  case foldl' round' (Sha256State a0 b0 c0 d0 e0 f0 g0 h0) (zip roundConstants messageSchedule) of
    Sha256State a b c d e f g h ->
      Sha256State (a + a0) (b + b0) (c + c0) (d + d0) (e + e0) (f + f0) (g + g0) (h + h0)
  where
    round' (Sha256State a b c d e f g h) (constant, scheduled) =
      let t1 = h + bigSigma1 e + choose e f g + constant + scheduled
          t2 = bigSigma0 a + majority a b c
       in Sha256State (t1 + t2) a b c (d + t1) e f g

    -- The message schedule, defined in terms of itself: the first sixteen
    -- words are the block's own, and every later one is expanded from the
    -- four words at the fixed distances the standard names — @W[t-2]@,
    -- @W[t-7]@, @W[t-15]@ and @W[t-16]@, which are the four inputs zipped
    -- here. Each word is a cons cell computed once and shared by the rounds
    -- reading it, so no round indexes into a list. The definition is
    -- unbounded and the 'zip' against the sixty-four constants is what stops
    -- it at sixty-four rounds.
    messageSchedule = schedule
      where
        schedule =
          initialWords
            <> zipWith4 expand (drop 14 schedule) (drop 9 schedule) (drop 1 schedule) schedule

    expand w2 w7 w15 w16 = smallSigma1 w2 + w7 + smallSigma0 w15 + w16

    initialWords = [beWord index | index <- [0 .. 15]]
    beWord index =
      foldl'
        (\accumulated offset -> accumulated * 256 + fromIntegral (ByteString.index block (index * 4 + offset)))
        (0 :: Word32)
        [0 .. 3]

choose :: Word32 -> Word32 -> Word32 -> Word32
choose x y z = (x .&. y) `xor` (complement x .&. z)

majority :: Word32 -> Word32 -> Word32 -> Word32
majority x y z = (x .&. y) `xor` (x .&. z) `xor` (y .&. z)

bigSigma0 :: Word32 -> Word32
bigSigma0 x = rotateR x 2 `xor` rotateR x 13 `xor` rotateR x 22

bigSigma1 :: Word32 -> Word32
bigSigma1 x = rotateR x 6 `xor` rotateR x 11 `xor` rotateR x 25

smallSigma0 :: Word32 -> Word32
smallSigma0 x = rotateR x 7 `xor` rotateR x 18 `xor` (x `shiftR` 3)

smallSigma1 :: Word32 -> Word32
smallSigma1 x = rotateR x 17 `xor` rotateR x 19 `xor` (x `shiftR` 10)

wordBytes :: Word32 -> [Word8]
wordBytes value = [fromIntegral (value `shiftR` shiftBy) | shiftBy <- [24, 16, 8, 0]]

hexByte :: Word8 -> Text
hexByte value = Text.justifyRight 2 '0' (Text.pack (showHex value ""))
