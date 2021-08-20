module Epsilon.Generator.ToJSON
  ( generate
  ) where

import qualified Epsilon.Constant.Module as Module
import qualified Epsilon.Generator.Common as Common
import qualified Epsilon.Hs as Hs
import qualified Epsilon.Hsc as Hsc
import qualified Epsilon.Options as Options
import qualified Epsilon.Type.Constructor as Constructor
import qualified Epsilon.Type.Field as Field
import qualified Epsilon.Type.Type as Type
import qualified GhcPlugins as Ghc

generate :: Common.Generator
generate lIdP lHsQTyVars lConDecls options srcSpan = do
  type_ <- Type.make lIdP lHsQTyVars lConDecls srcSpan
  case Type.constructors type_ of
    [_] -> pure ()
    _ -> Hsc.throwError srcSpan $ Ghc.text "requires exactly one constructor"

  modifyFieldName <-
    Common.applyAll
      <$> Options.parse (Common.fieldNameOptions srcSpan) options srcSpan

  fieldNames <-
    mapM (fromField modifyFieldName)
    . fmap Field.name
    . concatMap Constructor.fields
    $ Type.constructors type_

  aeson <- Common.makeRandomModule Module.data_aeson
  monoid <- Common.makeRandomModule Module.data_monoid
  text <- Common.makeRandomModule Module.data_text
  var1 <- Common.makeRandomVariable srcSpan "var_"
  var2 <- Common.makeRandomVariable srcSpan "var_"
  let
    lImportDecls = Hs.importDecls
      srcSpan
      [ (Module.data_aeson, aeson)
      , (Module.data_monoid, monoid)
      , (Module.data_text, text)
      ]

    toPair lRdrName (occName, fieldName) =
      Hs.opApp
          srcSpan
          (Hs.app srcSpan (Hs.qualVar srcSpan text $ Ghc.mkVarOcc "pack")
          . Hs.lit srcSpan
          $ Hs.string fieldName
          )
          (Hs.qualVar srcSpan aeson $ Ghc.mkVarOcc ".=")
        . Hs.app srcSpan (Hs.var srcSpan $ Hs.unqual srcSpan occName)
        $ Hs.var srcSpan lRdrName

    lHsExprs lRdrName = fmap (toPair lRdrName) fieldNames

    toJSON =
      Common.makeLHsBind
          srcSpan
          (Ghc.mkVarOcc "toJSON")
          [Hs.varPat srcSpan var1]
        . Hs.app srcSpan (Hs.qualVar srcSpan aeson $ Ghc.mkVarOcc "object")
        . Hs.explicitList srcSpan
        $ lHsExprs var1

    toEncoding =
      Common.makeLHsBind
          srcSpan
          (Ghc.mkVarOcc "toEncoding")
          [Hs.varPat srcSpan var2]
        . Hs.app srcSpan (Hs.qualVar srcSpan aeson $ Ghc.mkVarOcc "pairs")
        . Hs.par srcSpan
        . Hs.app srcSpan (Hs.qualVar srcSpan monoid $ Ghc.mkVarOcc "mconcat")
        . Hs.explicitList srcSpan
        $ lHsExprs var2

    lHsDecl = Common.makeInstanceDeclaration
      srcSpan
      type_
      aeson
      (Ghc.mkClsOcc "ToJSON")
      [toJSON, toEncoding]

  pure (lImportDecls, [lHsDecl])

fromField
  :: (String -> Ghc.Hsc String) -> Ghc.OccName -> Ghc.Hsc (Ghc.OccName, String)
fromField modifyFieldName occName = do
  fieldName <- modifyFieldName $ Ghc.occNameString occName
  pure (occName, fieldName)
