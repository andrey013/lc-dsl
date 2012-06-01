module LC_B_GLData where

import Control.Applicative
import Control.Monad
import Data.ByteString.Char8 (ByteString)
import Data.IORef
import Data.List as L
import Data.Maybe
import Data.Trie as T
import Foreign
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Vector as V

import Graphics.Rendering.OpenGL.Raw.Core32

import LC_B_GLType
import LC_B_GLUtil
import LC_G_APIType
import LC_U_APIType
import LC_U_DeBruijn

-- Buffer
compileBuffer :: [Array] -> IO Buffer
compileBuffer arrs = do
    let calcDesc (offset,setters,descs) (Array arrType cnt setter) =
          let size = cnt * sizeOfArrayType arrType
          in (size + offset, (offset,size,setter):setters, ArrayDesc arrType cnt offset size:descs)
        (bufSize,arrSetters,arrDescs) = foldl' calcDesc (0,[],[]) arrs
    bo <- alloca $! \pbo -> glGenBuffers 1 pbo >> peek pbo
    glBindBuffer gl_ARRAY_BUFFER bo
    glBufferData gl_ARRAY_BUFFER (fromIntegral bufSize) nullPtr gl_STATIC_DRAW
    forM_ arrSetters $! \(offset,size,setter) -> setter $! glBufferSubData gl_ARRAY_BUFFER (fromIntegral offset) (fromIntegral size)
    glBindBuffer gl_ARRAY_BUFFER 0
    return $! Buffer (V.fromList $! reverse arrDescs) bo

bufferSize :: Buffer -> Int
bufferSize = V.length . bufArrays

arraySize :: Buffer -> Int -> Int
arraySize buf arrIdx = arrLength $! bufArrays buf V.! arrIdx

arrayType :: Buffer -> Int -> ArrayType
arrayType buf arrIdx = arrType $! bufArrays buf V.! arrIdx

-- question: should we render the full stream?
--  answer: YES
-- Object
-- WARNING: sub network slot sharing is not supported at the moment!
addObject :: Renderer -> ByteString -> Primitive -> Maybe (IndexStream Buffer) -> Trie (Stream Buffer) -> [ByteString] -> IO Object
addObject renderer slotName prim objIndices objAttributes objUniforms = do
    let Just (slotType,sType) = T.lookup slotName $ slotStream renderer
        objSType = fmap streamToInputType objAttributes
        primType = case prim of
            TriangleStrip   -> Triangle
            TriangleList    -> Triangle
            TriangleFan     -> Triangle
            LineStrip       -> Line
            LineList        -> Line
            PointList       -> Point
        primGL = case prim of
            TriangleStrip   -> gl_TRIANGLE_STRIP
            TriangleList    -> gl_TRIANGLES
            TriangleFan     -> gl_TRIANGLE_FAN
            LineStrip       -> gl_LINE_STRIP
            LineList        -> gl_LINES
            PointList       -> gl_POINTS
        streamCounts = [c | Stream _ _ _ _ c <- T.elems objAttributes]
        count = head streamCounts

    -- validate
    unless (T.member slotName $! slotUniform renderer) $ fail $ "addObject: slot name mismatch: " ++ show slotName
    when (slotType /= primType) $ fail $ "addObject: primitive type mismatch: " ++ show (slotType,primType)
    when (objSType /= sType) $ fail $ unlines
        [ "addObject: attribute mismatch"
        , "expected:"
        , "  " ++ show sType
        , "actual:"
        , "  " ++ show objSType
        ]
    when (L.null streamCounts) $ fail "addObject: missing stream attribute, a least one stream attribute is required!"
    when (L.or [c /= count | c <- streamCounts]) $ fail "addObject: streams should have the same length!"
    --unless (and [T.member n uLocs | n <- objUniforms]) $ fail "addObject: unknown slot uniform!"

    -- validate index type if presented and create draw action
    (iSetup,draw) <- case objIndices of
        Nothing -> return (glBindBuffer gl_ELEMENT_ARRAY_BUFFER 0, glDrawArrays primGL 0 (fromIntegral count))
        Just (IndexStream (Buffer arrs bo) arrIdx start idxCount) -> do
            -- setup index buffer
            let ArrayDesc arrType arrLen arrOffs arrSize = arrs V.! arrIdx
                glType = arrayTypeToGLType arrType
                ptr    = intPtrToPtr $! fromIntegral (arrOffs + start * sizeOfArrayType arrType)
            -- validate index type
            when (notElem arrType [ArrWord8, ArrWord16, ArrWord32]) $ fail "addObject: index type should be unsigned integer type"
            return (glBindBuffer gl_ELEMENT_ARRAY_BUFFER bo, glDrawElements primGL (fromIntegral idxCount) glType ptr)
{-
        Just objSet = T.lookup slotName (objectSet renderer)
    --FIXME: modifyIORef objSet (renderFun:)
-}
{-
data RenderDescriptor
    = RenderDescriptor
    { uniformLocation   :: Trie GLint   -- Uniform name -> GLint
    , streamLocation    :: Trie GLuint  -- Attribute name -> GLuint
    , renderAction      :: IO ()
    , disposeAction     :: IO ()
    , drawObjectsIORef  :: IORef ObjectSet  -- updated internally, according objectSet
                                            -- hint: Map is required to support slot sharing across different Accumulation nodes,
                                            --       because each node requires it's own render action list: [IO ()]
    }

data SlotDescriptor
    = SlotDescriptor
    { attachedGP        :: Set GP
    , objectSet         :: IORef (Set Object)       -- objects, added to this slot (set by user)
    }

data ObjectSet
    = ObjectSet
    { drawObject    :: IO ()
    , drawObjectMap :: Map Object (IO ())
    }

    = Renderer
    -- public
    { slotUniform           :: Trie (Trie InputType)
    , slotStream            :: Trie (PrimitiveType, Trie InputType)
    , uniformSetter         :: Trie InputSetter         -- global uniform
    , render                :: IO ()
    , dispose               :: IO ()

    -- internal
    , mkUniformSetup        :: Trie (GLint -> IO ())    -- global unifiorm
    , slotDescriptor        :: Trie SlotDescriptor
    , renderDescriptor      :: Map GP RenderDescriptor
    }
-}
    --mkUniformSetter :: InputType -> IO (GLint -> IO (), InputSetter)
    let renderDescriptorMap = renderDescriptor renderer
        uniformType     = T.fromList $ concat [T.toList t | (_,t) <- T.toList $ slotUniform renderer]
        mkUSetup        = mkUniformSetup renderer
        globalUNames    = Set.toList $! (Set.fromList $! T.keys uniformType) Set.\\ (Set.fromList objUniforms)
        
    (mkObjUSetup,objUSetters) <- unzip <$> (sequence [mkUniformSetter t | n <- objUniforms, t <- maybeToList $ T.lookup n uniformType])
    let objUSetterTrie = T.fromList $! zip objUniforms objUSetters
    
        mkDrawAction :: GP -> IO (GLuint,IO ())
        mkDrawAction gp = do
            {-
            -- create uniform setup action
            let Just uTypes = T.lookup slotName (slotUniform renderer)
            let 
            -}
            let Just rd = Map.lookup gp renderDescriptorMap
                sLocs   = streamLocation rd
                uLocs   = uniformLocation rd
                -- stream setup action
                sSetup          = sequence_ [ mkSSetter t loc s 
                                            | (n,s) <- T.toList objAttributes
                                            ,     t <- maybeToList $ T.lookup n sType
                                            ,   loc <- maybeToList $ T.lookup n sLocs
                                            ]
                -- global uniform setup
                globalUSetup    = sequence_ [ mkUS loc 
                                            | n <- globalUNames
                                            , let Just mkUS = T.lookup n mkUSetup
                                            , loc <- maybeToList $ T.lookup n uLocs
                                            ]
                -- object uniform setup
                objUSetup       = zipWithM_ (\n mkOUS -> let Just loc = T.lookup n uLocs in mkOUS loc) objUniforms mkObjUSetup
            --print sLocs
            -- create Vertex Array Object
            vao <- alloca $! \pvao -> glGenVertexArrays 1 pvao >> peek pvao
            glBindVertexArray vao
            sSetup -- setup vertex attributes
            iSetup -- setup index buffer
            let renderFun = do
                    --print "draw object"
                    globalUSetup            -- setup uniforms
                    objUSetup
                    glBindVertexArray vao   -- setup stream input (aka object attributes)
                    draw                    -- execute draw function
            return (vao,renderFun)

        Just (SlotDescriptor gps objSetRef) = T.lookup slotName (slotDescriptor renderer)
        gpList = Set.toList gps
    {-
      TODO:
        - create the object draw action for every Accumulate node
        - update ObjectSet's draw action lists
    -}
    --print sType
    (vaoList,drawList) <- unzip <$> mapM mkDrawAction gpList
    let obj = Object
            { objectSlotName        = slotName
            , objectUniformSetter   = objUSetterTrie
            , vertexArrayObject     = vaoList
            }

    -- add object to slot's object set
    modifyIORef objSetRef $ \s -> Set.insert obj s

    -- add draw object action to list
    forM_ (zip gpList drawList) $ \(gp,draw) -> do
        --print ("add", vaoList)
        let Just rd = Map.lookup gp renderDescriptorMap
        modifyIORef (drawObjectsIORef rd) $ \(ObjectSet _ drawMap) ->
            let drawMap' = Map.insert obj draw drawMap
            in ObjectSet (sequence_ $ Map.elems drawMap') drawMap'

    return obj

{-
    = SlotDescriptor
    { attachedGP        :: Set GP
    , objectSet         :: IORef (Set Object)       -- objects, added to this slot (set by user)
    }
-}
removeObject :: Renderer -> Object -> IO ()
removeObject rend obj = do
    let Just (SlotDescriptor gps objSetRef) = T.lookup (objectSlotName obj) (slotDescriptor rend)
        renderDescriptorMap = renderDescriptor rend

    -- remove object from slot's object set
    modifyIORef objSetRef $ \s -> Set.delete obj s

    -- remove draw object action from list
    forM_ (Set.toList gps) $ \gp -> do
        let Just rd = Map.lookup gp renderDescriptorMap
        modifyIORef (drawObjectsIORef rd) $ \(ObjectSet _ drawMap) ->
            let drawMap' = Map.delete obj drawMap
            in ObjectSet (sequence_ $ Map.elems drawMap') drawMap'