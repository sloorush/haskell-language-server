{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Ide.Plugin.CodeRange (
    descriptor
    , Log

    -- * Internal
    , findPosition
    , findFoldingRanges
    , createFoldingRange
    , findDocumentLinks
    ) where

import           Control.Monad.Except                 (ExceptT (ExceptT),
                                                       runExceptT)
import           Control.Monad.IO.Class               (liftIO)
import           Control.Monad.Trans.Maybe            (MaybeT (MaybeT),
                                                       maybeToExceptT)
import           Data.Aeson                           (Value)
import           Data.Either.Extra                    (maybeToEither)
import           Data.Maybe
import           Data.Text                            (Text)

import           Data.Vector                          (Vector)
import qualified Data.Vector                          as V
import           Development.IDE                      (IdeAction,
                                                       IdeState (shakeExtras),
                                                       Range (Range), Recorder,
                                                       WithPriority,
                                                       cmapWithPrio,
                                                       runIdeAction,
                                                       toNormalizedFilePath',
                                                       uriToFilePath')
import           Development.IDE.Core.Actions         (useE)
import           Development.IDE.Core.FileStore       (getFileContents)
import           Development.IDE.Core.PositionMapping (PositionMapping,
                                                       fromCurrentPosition,
                                                       toCurrentRange)
import           Development.IDE.Core.Rules           (runAction)
import           Development.IDE.Types.Logger         (Pretty (..))
import           Ide.Plugin.CodeRange.Rules           (CodeRange (..),
                                                       GetCodeRange (..),
                                                       codeRangeRule, crkToFrk)
import qualified Ide.Plugin.CodeRange.Rules           as Rules (Log)
import           Ide.PluginUtils                      (pluginResponse,
                                                       positionInRange)
import           Ide.Types                            (PluginDescriptor (pluginHandlers, pluginRules),
                                                       PluginId,
                                                       defaultPluginDescriptor,
                                                       mkPluginHandler)
import           Language.LSP.Server                  (LspM)
import           Language.LSP.Types                   (DocumentLink (DocumentLink),
                                                       DocumentLinkParams (..),
                                                       FoldingRange (..),
                                                       FoldingRangeParams (..),
                                                       List (List),
                                                       NormalizedFilePath,
                                                       Position (..),
                                                       Range (_start),
                                                       ResponseError,
                                                       SMethod (STextDocumentDocumentLink, STextDocumentFoldingRange, STextDocumentSelectionRange),
                                                       SelectionRange (..),
                                                       SelectionRangeParams (..),
                                                       TextDocumentIdentifier (TextDocumentIdentifier),
                                                       Uri)
import           Prelude                              hiding (log, span)
import           Text.Regex.TDFA                      (AllTextMatches (getAllTextMatches),
                                                       (=~))

descriptor :: Recorder (WithPriority Log) -> PluginId -> PluginDescriptor IdeState
descriptor recorder plId = (defaultPluginDescriptor plId)
    { pluginHandlers = mkPluginHandler STextDocumentSelectionRange selectionRangeHandler
    <> mkPluginHandler STextDocumentFoldingRange foldingRangeHandler
    <> mkPluginHandler STextDocumentDocumentLink documentLinkHandler
    , pluginRules = codeRangeRule (cmapWithPrio LogRules recorder)
    }

data Log = LogRules Rules.Log

instance Pretty Log where
    pretty log = case log of
        LogRules codeRangeLog -> pretty codeRangeLog

documentLinkHandler :: IdeState -> PluginId -> DocumentLinkParams -> LspM c (Either ResponseError (List DocumentLink))
documentLinkHandler ide _ DocumentLinkParams{..} = do
    pluginResponse $ do
        filePath <- ExceptT . pure . maybeToEither "fail to convert uri to file path" $
                toNormalizedFilePath' <$> uriToFilePath' uri
        documentLinks <- ExceptT . liftIO . runIdeAction "DocumentLinks" (shakeExtras ide) . runExceptT $
            getDocumentLinks filePath ide
        pure . List $ documentLinks
    where
        uri :: Uri
        TextDocumentIdentifier uri = _textDocument

foldingRangeHandler :: IdeState -> PluginId -> FoldingRangeParams -> LspM c (Either ResponseError (List FoldingRange))
foldingRangeHandler ide _ FoldingRangeParams{..} = do
    pluginResponse $ do
        filePath <- ExceptT . pure . maybeToEither "fail to convert uri to file path" $
                toNormalizedFilePath' <$> uriToFilePath' uri
        foldingRanges <- ExceptT . liftIO . runIdeAction "FoldingRange" (shakeExtras ide) . runExceptT $
            getFoldingRanges filePath
        pure . List $ removeDupStartLineFoldings foldingRanges
    where
        uri :: Uri
        TextDocumentIdentifier uri = _textDocument

getDocumentLinks :: NormalizedFilePath -> IdeState -> ExceptT String IdeAction [DocumentLink]
getDocumentLinks file state = do
    (_, fileContents) <- liftIO $ runAction "GADT.GetFileContents" state $ getFileContents file

    let documentLinks = findDocumentLinks fileContents

    maybeToExceptT "Fail to generate Document Links" (MaybeT . pure $ Just $ catMaybes documentLinks)

getFoldingRanges :: NormalizedFilePath -> ExceptT String IdeAction [FoldingRange]
getFoldingRanges file = do
    (codeRange, _) <- maybeToExceptT "fail to get code range" $ useE GetCodeRange file

    let foldingRanges = findFoldingRanges codeRange

    maybeToExceptT "Fail to generate folding range" (MaybeT . pure $ Just foldingRanges)

selectionRangeHandler :: IdeState -> PluginId -> SelectionRangeParams -> LspM c (Either ResponseError (List SelectionRange))
selectionRangeHandler ide _ SelectionRangeParams{..} = do
    pluginResponse $ do
        filePath <- ExceptT . pure . maybeToEither "fail to convert uri to file path" $
                toNormalizedFilePath' <$> uriToFilePath' uri
        selectionRanges <- ExceptT . liftIO . runIdeAction "SelectionRange" (shakeExtras ide) . runExceptT $
            getSelectionRanges filePath positions
        pure . List $ selectionRanges
  where
    uri :: Uri
    TextDocumentIdentifier uri = _textDocument

    positions :: [Position]
    List positions = _positions

getSelectionRanges :: NormalizedFilePath -> [Position] -> ExceptT String IdeAction [SelectionRange]
getSelectionRanges file positions = do
    (codeRange, positionMapping) <- maybeToExceptT "fail to get code range" $ useE GetCodeRange file
    -- 'positionMapping' should be appied to the input before using them
    positions' <- maybeToExceptT "fail to apply position mapping to input positions" . MaybeT . pure $
        traverse (fromCurrentPosition positionMapping) positions

    let selectionRanges = flip fmap positions' $ \pos ->
            -- We need a default selection range if the lookup fails, so that other positions can still have valid results.
            let defaultSelectionRange = SelectionRange (Range pos pos) Nothing
             in fromMaybe defaultSelectionRange . findPosition pos $ codeRange

    -- 'positionMapping' should be applied to the output ranges before returning them
    maybeToExceptT "fail to apply position mapping to output positions" . MaybeT . pure $
         traverse (toCurrentSelectionRange positionMapping) selectionRanges

-- | Find 'Position' in 'CodeRange'. This can fail, if the given position is not covered by the 'CodeRange'.
findPosition :: Position -> CodeRange -> Maybe SelectionRange
findPosition pos root = go Nothing root
  where
    -- Helper function for recursion. The range list is built top-down
    go :: Maybe SelectionRange -> CodeRange -> Maybe SelectionRange
    go acc node =
        if positionInRange pos range
        then maybe acc' (go acc') (binarySearchPos children)
        -- If all children doesn't contain pos, acc' will be returned.
        -- acc' will be Nothing only if we are in the root level.
        else Nothing
      where
        range = _codeRange_range node
        children = _codeRange_children node
        acc' = Just $ maybe (SelectionRange range Nothing) (SelectionRange range . Just) acc

    binarySearchPos :: Vector CodeRange -> Maybe CodeRange
    binarySearchPos v
        | V.null v = Nothing
        | V.length v == 1,
            Just r <- V.headM v = if positionInRange pos (_codeRange_range r) then Just r else Nothing
        | otherwise = do
            let (left, right) = V.splitAt (V.length v `div` 2) v
            startOfRight <- _start . _codeRange_range <$> V.headM right
            if pos < startOfRight then binarySearchPos left else binarySearchPos right

-- | Traverses through the code range and children to a folding ranges
findFoldingRanges :: CodeRange -> [FoldingRange]
findFoldingRanges r@(CodeRange _ children _) =
  let frRoot :: [FoldingRange] = case createFoldingRange r of
        Just x  -> [x]
        Nothing -> []

      frChildren :: [FoldingRange] = concat $ V.toList $ fmap findFoldingRanges children
   in frRoot ++ frChildren

findDocumentLinks :: Maybe Text -> [Maybe DocumentLink]
findDocumentLinks fc = case fc of
    Just fc -> urlToDocumentLink $ parseTextToUrls fc
    Nothing -> []

urlRegEx :: String
urlRegEx = "(https?:\\/\\/(?:www\\.|(?!www))[a-zA-Z0-9][a-zA-Z0-9-]+[a-zA-Z0-9]\\.[^\\s]{2,}|www\\.[a-zA-Z0-9][a-zA-Z0-9-]+[a-zA-Z0-9]\\.[^\\s]{2,}|https?:\\/\\/(?:www\\.|(?!www))[a-zA-Z0-9]+\\.[^\\s]{2,}|www\\.[a-zA-Z0-9]+\\.[^\\s]{2,})"

parseTextToUrls :: Text -> [Text]
parseTextToUrls fc = getAllTextMatches(fc =~ urlRegEx) :: [Text]


urlToDocumentLink :: [Text] -> [Maybe DocumentLink]
urlToDocumentLink l = do
    let docLink :: Maybe DocumentLink = makeDocumentLink (Range (Position 0 0) (Position 0 10)) Nothing (Just "aaya") Nothing

    case docLink of
        Just _  -> [docLink]
        Nothing -> [Just (DocumentLink (Range (Position 0 0) (Position 0 10)) Nothing (Just "noob ni aaya") Nothing)]

makeDocumentLink :: Range -> Maybe Uri -> Maybe Text -> Maybe Value -> Maybe DocumentLink
makeDocumentLink r uri tooltip xdata = do
    case uri of
        Just _  -> Just (DocumentLink r uri tooltip xdata)
        Nothing -> Nothing

-- | Parses code range to folding range
createFoldingRange :: CodeRange -> Maybe FoldingRange
createFoldingRange (CodeRange (Range (Position lineStart charStart) (Position lineEnd charEnd)) _ ck) = do
    let frk = crkToFrk ck
    if lineStart == lineEnd
        then Nothing
    else case frk of
        Just _  -> Just (FoldingRange lineStart (Just charStart) lineEnd (Just charEnd) frk)
        Nothing -> Nothing

-- Removes all small foldings that start from the same line
removeDupStartLineFoldings :: [FoldingRange] -> [FoldingRange]
removeDupStartLineFoldings [] = []
removeDupStartLineFoldings [x] = [x]
removeDupStartLineFoldings (frx@(FoldingRange x _ _ _ _):xs@((FoldingRange y _ _ _ _):xs2))
    | x == y = removeDupStartLineFoldings (frx:xs2)
    | otherwise = frx : removeDupStartLineFoldings xs

-- | Likes 'toCurrentPosition', but works on 'SelectionRange'
toCurrentSelectionRange :: PositionMapping -> SelectionRange -> Maybe SelectionRange
toCurrentSelectionRange positionMapping SelectionRange{..} = do
    newRange <- toCurrentRange positionMapping _range
    pure $ SelectionRange {
        _range = newRange,
        _parent = _parent >>= toCurrentSelectionRange positionMapping
    }
