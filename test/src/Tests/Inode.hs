{-# LANGUAGE Rank2Types, FlexibleContexts #-}
module Tests.Inode
  (
   qcProps
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Prelude hiding (read)
import Test.QuickCheck hiding (numTests)
import Test.QuickCheck.Monadic

import Halfs.BlockMap
import Halfs.Classes
import Halfs.CoreAPI
import Halfs.Errors
import Halfs.HalfsState
import Halfs.Inode
import Halfs.Monad
import Halfs.Protection
import Halfs.SuperBlock
import Halfs.Types

import System.Device.BlockDevice (BlockDevice(..))
import Tests.Instances           (printableBytes)
import Tests.Types
import Tests.Utils

-- import Debug.Trace


--------------------------------------------------------------------------------
-- Inode properties

qcProps :: Bool -> [(Args, Property)]
qcProps quick =
  [ -- Inode module invariants
   exec 10 "Inode module invariants" propM_inodeModuleInvs
  , -- Inode stream write/read/(over)write/read property
   exec 10 "Basic WRWR" propM_basicWRWR
  , -- Inode stream write/read/(truncating)write/read property
    exec 10 "Truncating WRWR" propM_truncWRWR
  , -- Inode length-specific stream write/read
    exec 10 "Length-specific WR" propM_lengthWR
  ]
  where
    exec = mkMemDevExec quick "Inode"


--------------------------------------------------------------------------------
-- Property Implementations

-- Note that in many of these properties we compare timestamps using <
-- and >; these may need to be <= and >= if the underlying clock
-- resolution is too coarse!

-- | Tests Inode module invariants
propM_inodeModuleInvs :: HalfsCapable b t r l m =>
                         BDGeom
                      -> BlockDevice m
                      -> PropertyM m ()
propM_inodeModuleInvs _g _dev = do
  -- Check geometry/padding invariants
  minInodeSz <- runH $ minimalInodeSize =<< getTime
  minContSz  <- runH $ minimalContSize
  assert (minInodeSz == minContSz)

-- | Tests basic write/reads & overwrites
propM_basicWRWR :: HalfsCapable b t r l m =>
                   BDGeom
                -> BlockDevice m
                -> PropertyM m ()
propM_basicWRWR _g dev = do
  withFSData dev $ \fs rdirIR dataSz testData -> do
  let dataSzI      = fromIntegral dataSz
      doWrite      = writeStream dev (hsBlockMap fs) rdirIR
      doRead       = readStream dev rdirIR
      checkWriteMD t = \sz eb -> chk sz eb (t <) (t <)
      checkReadMD  t = \sz eb -> chk sz eb (t <) (t >)
      chk          = checkInodeMetadata fs rdirIR Directory rootDirPerms
                                        rootUser rootGroup

  -- Expected error: attempted write past end of (empty) stream
  e0 <- runH $ doWrite (bdBlockSize dev) False testData
  case e0 of
    Left (HalfsInvalidStreamIndex idx) -> assert (idx == bdBlockSize dev)
    _                                  -> assert False
                                        
  -- TODO/FIXME: We need to catch byte offset errors, not just block/cont offset
  -- errors

{-
  e0' <- runH $ writeStream dev bm rdirIR 5 False testData
  case e0' of
    Left (HalfsInvalidStreamIndex idx) -> assert (idx == 1)
   _                                   -> assert False
-}

  (_, _, api, apc) <- exec "Obtaining sizes" $ getSizes (bdBlockSize dev)
  let expBlks = calcExpBlockCount (bdBlockSize dev) api apc dataSz

  -- Non-truncating write & read-back
  t1 <- time
  exec "Non-truncating write" $ doWrite 0 False testData
  checkWriteMD t1 dataSzI expBlks

  -- Check readback contents
  t2  <- time
  bs1 <- exec "Readback 1" $ doRead 0 Nothing
  checkReadMD t2 dataSz expBlks 
  assert (testData == bsTake dataSz bs1)
  -- ^ We leave off the trailing bytes of what we read, since reading until the
  -- end of the stream will include contents of the whole last block

  -- Non-truncating overwrite & read-back
  forAllM (choose (1, dataSz `div` 2))     $ \overwriteSz -> do 
  forAllM (choose (0, dataSz `div` 2 - 1)) $ \startByte   -> do
  forAllM (printableBytes overwriteSz)     $ \newData     -> do

  t3 <- time
  exec "Non-trunc overwrite" $ doWrite (fromIntegral startByte) False newData
  checkWriteMD t3 dataSzI expBlks

  -- Check readback contents
  t4  <- time
  bs2 <- exec "Readback 2" $ doRead 0 Nothing
  checkReadMD t4 dataSz expBlks
  let readBack = bsTake dataSz bs2
      expected = bsTake startByte testData
                 `BS.append`
                 newData
                 `BS.append`
                 bsDrop (startByte + overwriteSz) testData
  assert (readBack == expected)
  where
    time = exec "obtain time" getTime
    exec = execH "propM_basicWRWR"

-- | Tests truncate writes and read-backs of random size
propM_truncWRWR :: HalfsCapable b t r l m =>
                   BDGeom
                -> BlockDevice m
                -> PropertyM m ()
propM_truncWRWR _g dev = do
  withFSData dev $ \fs rdirIR dataSz testData -> do
  let numFree      = sreadRef $ bmNumFree $ hsBlockMap fs
      doRead       = readStream dev rdirIR
      doWrite      = writeStream dev (hsBlockMap fs) rdirIR
      checkWriteMD t = \sz eb -> chk sz eb (t <) (t <)
      checkReadMD  t = \sz eb -> chk sz eb (t <) (t >)
      chk          = checkInodeMetadata fs rdirIR Directory rootDirPerms
                                        rootUser rootGroup

  (_, _, api, apc) <- exec "Obtaining sizes" $ getSizes (bdBlockSize dev)
  let expBlks = calcExpBlockCount (bdBlockSize dev) api apc

  -- Non-truncating write
  t1 <- time
  exec "Non-truncating write" $ doWrite 0 False testData
  checkWriteMD t1 dataSz (expBlks dataSz) 

  forAllM (choose (dataSz `div` 8, dataSz `div` 4)) $ \dataSz'   -> do
  forAllM (printableBytes dataSz')                  $ \testData' -> do 
  forAllM (choose (1, dataSz - dataSz' - 1))        $ \truncIdx  -> do
  let dataSz'' = dataSz' + truncIdx
  freeBlks <- numFree -- Free blks before truncate

  -- Truncating write
  t2 <- time
  exec "Truncating write" $ doWrite (fromIntegral truncIdx) True testData'
  checkWriteMD t2 dataSz'' (expBlks dataSz'')

  -- Read until the end of the stream and check truncation       
  t3 <- time
  bs <- exec "Readback" $ doRead (fromIntegral truncIdx) Nothing
  checkReadMD t3 dataSz'' (expBlks dataSz'')
  assert (BS.length bs >= BS.length testData')
  assert (bsTake dataSz' bs == testData')
  assert (all (== truncSentinel) $ BS.unpack $ bsDrop dataSz' bs)

  -- Sanity check the BlockMap's free count
  freeBlks' <- numFree  -- Free blks after truncate
  let minExpectedFree = -- May also have frees on Cont storage, so this
                        -- is just a lower bound
        (dataSz - dataSz'') `div` (fromIntegral $ bdBlockSize dev)
  assert $ minExpectedFree <= fromIntegral (freeBlks' - freeBlks)
  where
    time = exec "obtain time" getTime
    exec = execH "propM_truncWRWR"

-- | Tests bounded reads of random offset and length
propM_lengthWR :: HalfsCapable b t r l m =>
                  BDGeom
               -> BlockDevice m
               -> PropertyM m ()
propM_lengthWR _g dev = do
  withFSData dev $ \fs rdirIR dataSz testData -> do 
  let blkSz          = bdBlockSize dev
      checkWriteMD t = \sz eb -> chk sz eb (t <) (t <)
      checkReadMD  t = \sz eb -> chk sz eb (t <) (t >)
      chk            = checkInodeMetadata fs rdirIR Directory rootDirPerms
                                          rootUser rootGroup 

  (_, _, api, apc) <- exec "Obtaining sizes" $ getSizes (bdBlockSize dev)
  let expBlks = calcExpBlockCount blkSz api apc dataSz

  -- Write random data to the stream
  t1 <- time
  exec "Populate" $ writeStream dev (hsBlockMap fs) rdirIR 0 False testData
  checkWriteMD t1 dataSz expBlks 

  -- If possible, read a minimum of one full inode + 1 byte worth of data
  -- into the next inode to push on boundary conditions & spill arithmetic.
  forAllM (arbitrary :: Gen Bool) $ \b -> do
  blksPerCarrier <- run $ if b
                          then computeNumInodeAddrsM blkSz
                          else computeNumContAddrsM  blkSz
  let minReadLen = min dataSz (fromIntegral $ blksPerCarrier * blkSz + 1)

  forAllM (choose (minReadLen, dataSz))  $ \readLen  -> do
  forAllM (choose (0, dataSz - 1))       $ \startIdx -> do

  let readLen' = min readLen (dataSz - startIdx)
      stIdxW64 = fromIntegral startIdx

  t2 <- time
  bs <- exec "Bounded readback" $
          readStream dev rdirIR stIdxW64 (Just $ fromIntegral readLen')
  assert (bs == bsTake readLen' (bsDrop startIdx testData))
  checkReadMD t2 dataSz expBlks 
  where
    time = exec "obtain time" getTime
    exec = execH "propM_lengthWR"

withFSData :: HalfsCapable b t r l m =>
              BlockDevice m
           -> (HalfsState b r l m -> InodeRef -> Int -> ByteString -> PropertyM m ())
           -> PropertyM m ()
withFSData dev f = do
  fs <- runH (newfs dev) >> mountOK dev
  rdirIR <- rootDir `fmap` sreadRef (hsSuperBlock fs)
  withData dev $ f fs rdirIR 

newtype FillBlocks a = FillBlocks a deriving Show
newtype SpillCnt a   = SpillCnt a deriving Show

-- Generates random data of random size between 1/8 - 1/4 of the device
withData :: HalfsCapable b t r l m =>
            BlockDevice m                          -- The blk dev
         -> (Int -> ByteString -> PropertyM m ())  -- Action
         -> PropertyM m ()
withData dev f = do
  nAddrs <- run $ computeNumContAddrsM (bdBlockSize dev)
  let maxBlocks = safeToInt $ bdNumBlocks dev
      lo        = maxBlocks `div` 8
      hi        = maxBlocks `div` 4
      fbr       = FillBlocks `fmap` choose (lo, hi)
      scr       = SpillCnt   `fmap` choose (0, safeToInt nAddrs)
  forAllM fbr $ \(FillBlocks fillBlocks) -> do
  forAllM scr $ \(SpillCnt   spillCnt)   -> do
  -- fillBlocks is the number of blocks to fill on the write (1/8 - 1/4 of dev)
  -- spillCnt is the number of blocks to write into the last cont in the chain
  let dataSz = fillBlocks * safeToInt (bdBlockSize dev) + spillCnt
  forAllM (printableBytes dataSz) (f dataSz)
          
checkInodeMetadata :: (HalfsCapable b t r l m, Integral a) =>
                      HalfsState b r l m
                   -> InodeRef
                   -> FileType    -- expected filetype
                   -> FileMode    -- expected filemode
                   -> UserID      -- expected userid
                   -> GroupID     -- expected groupid
                   -> a           -- expected filesize
                   -> a           -- expected allocated block count 
                   -> (t -> Bool) -- access time predicate
                   -> (t -> Bool) -- modification time predicate
                   -> PropertyM m ()
checkInodeMetadata fs inr expFileTy expMode expUsr expGrp
                   expFileSz expNumBlocks accessp modifyp = do
  st <- execH "checkInodeMetadata" "filestat" $ fileStat fs inr
  checkFileStat st expFileSz expFileTy expMode
                expUsr expGrp expNumBlocks accessp modifyp
