module LC_T_HOAS where

import Data.ByteString.Char8
import Data.Typeable
import Data.Int

import TypeLevel.Number.Nat
import TypeLevel.Number.Nat.Num

import LCType

import LC_APIType
import LC_T_APIType
import LC_T_DSLType
import LC_T_PrimFun

class Exp exp where
    type Exp_GP exp :: * -> *
    type Exp_Input exp :: * -> *
    type Exp_PrimFun exp :: * -> * -> *
    type Exp_Texture exp :: (* -> *) -> * -> * -> * -> * -> *
    type Exp_Tuple exp :: (* -> *) -> * -> *
    type Exp_TupleIdx exp :: * -> * -> *

    -- Needed for conversion to de Bruijn form
    tag     :: GPU t
            => Int
            -> exp stage t
                 -- environment size at defining occurrence

    -- constant value
    cnst    :: IsScalar t
            => t
            -> exp stage t

    -- builtin variable
    primVar :: (GPU t
               , Input input, input ~ Exp_Input exp)
            => input t
            -> exp stage t

    -- uniform value
    uni     :: (GPU t
               , Input input, input ~ Exp_Input exp)
            => input t
            -> exp stage t

    -- conditional expression
    cond    :: GPU t
            => exp stage Bool
            -> exp stage t
            -> exp stage t
            -> exp stage t

    primApp :: (GPU a, GPU r
               , PrimFun primFun, primFun ~ Exp_PrimFun exp)
            => primFun stage (a -> r)
            -> exp stage a
            -> exp stage r

    -- tuple support
    tup     :: (GPU t, IsTuple t
               , Tuple tuple, tuple ~ Exp_Tuple exp)
            => tuple (exp stage) (TupleRepr t)
            -> exp stage t

    prj     :: (GPU e, GPU t, IsTuple t
               , TupleIdx tupleIdx, tupleIdx ~ Exp_TupleIdx exp)
            => tupleIdx (TupleRepr t) e
            -> exp stage t
            -> exp stage e

    -- sampler support
    sampler :: (GPU (Sampler dim arr t ar)
               , GP gp, gp ~ Exp_GP exp
               , Texture texture, texture ~ Exp_Texture exp)
            => Filter
            -> EdgeMode
            -> texture gp dim arr t ar
            -> exp stage (Sampler dim arr t ar)

type InterpolatedFlatExp exp stage a = (Interpolated interpolated, FlatTuple flatTuple) => flatTuple GPU (interpolated (exp stage)) a
type FlatExp exp stage a = FlatTuple flatTuple => flatTuple GPU (exp stage) a

-- Vertex
{-
    Vertex shader builtin output:
            gl_PerVertex {
                vec4  gl_Position
                float gl_PointSize
                float gl_ClipDistance[]
            }
-}
-- TODO: add support for gl_ClipDistance setup
-- result of a vertex shader function

class VertexOut vertexOut where
    type VertexOut_Exp vertexOut :: * -> * -> *

    vertexOut   :: (Exp exp, exp ~ VertexOut_Exp vertexOut)
                => exp V V4F      -- position
                -> exp V Float    -- point size
                -> InterpolatedFlatExp exp V a
                -> vertexOut (FTRepr a)

-- Geometry
-- describes a geometry shader
class GeometryShader geometryShader where
    type GeometryShader_Exp geometryShader :: * -> * -> *
    type GeometryShader_GeometryOut geometryShader :: * -> *

    noGeometryShader    :: geometryShader prim prim N1 a a

    geometryShader      :: (GPU (PrimitiveVertices primIn a), GPU i, GPU j, GPU b, IsPrimitive primIn, IsPrimitive primOut, Nat layerNum
                           , Exp exp, exp ~ GeometryShader_Exp geometryShader
                           , GeometryOut geometryOut, geometryOut ~ GeometryShader_GeometryOut geometryShader
                           )
                        => layerNum                                                 -- geometry shader:
                        -> primOut                                                  -- output primitive
                        -> Int                                                      -- max amount of generated vertices
                        -> (exp G (PrimitiveVertices primIn a) -> exp G (i,Int32))  -- how many primitives?
                        -> (exp G i -> exp G (i,j,Int32))                           -- how many vertices?
                        -> (exp G j -> geometryOut (j,b))                           -- generate vertices
                        -> geometryShader primIn primOut layerNum a b

{-
    Geometry shader builtin output:
            gl_PerVertex {
                vec4  gl_Position
                float gl_PointSize
                float gl_ClipDistance[]
            }
            int gl_PrimitiveID
            int gl_Layer
-}
-- result of a geometry shader function
class GeometryOut geometryOut where
    type GeometryOut_Exp geometryOut :: * -> * -> *

    geometryOut :: (Exp exp, exp ~ GeometryOut_Exp geometryOut)
                => exp G V4F      -- position
                -> exp G Float    -- point size
                -> exp G Int32    -- primitive ID
                -> exp G Int32    -- layer
                -> exp G j
                -> InterpolatedFlatExp exp G a
                -> geometryOut (j,(FTRepr a))

-- Fragment
{-
    Fragment shader builtin output:
            float gl_FragDepth  -- Optional
-}
-- result of a fragment shader function
class FragmentOut fragmentOut where
    type FragmentOut_Exp fragmentOut :: * -> * -> *

    fragmentOut             :: (Exp exp, exp ~ FragmentOut_Exp fragmentOut)
                            => FlatExp exp F a
                            -> fragmentOut (ColorRepr a)

    fragmentOutDepth        :: (Exp exp, exp ~ FragmentOut_Exp fragmentOut)
                            => exp F Float
                            -> FlatExp exp F a
                            -> fragmentOut (Depth Float :+: ColorRepr a)

    fragmentOutRastDepth    :: (Exp exp, exp ~ FragmentOut_Exp fragmentOut)
                            => FlatExp exp F a
                            -> fragmentOut (Depth Float :+: ColorRepr a)

-- fragment filter function, we express discard using a filter function
class FragmentFilter fragmentFilter where
    type FragmentFilter_Exp fragmentFilter :: * -> * -> *

    passAll :: fragmentFilter a

    filter  :: (Exp exp, exp ~ FragmentFilter_Exp fragmentFilter)
            => (exp F a -> exp F Bool)
            -> fragmentFilter a

-- hint: GP stands for Graphics Pipeline
-- GP AST
class GP gp where
    type GP_Exp gp :: * -> * -> *
    type GP_VertexOut gp :: * -> *
    type GP_GeometryShader gp :: * -> * -> * -> * -> * -> *
    type GP_RasterContext gp :: * -> *
    type GP_FragmentOut gp :: * -> *
    type GP_FragmentFilter gp :: * -> *

    -- Needed for conversion to de Bruijn form
    gpTag           :: Typeable a
                    => Int
                    -> gp a -- FIXME: restrict valid types to shareable types

    fetch           :: (InputTuple a, SGPU (InputTupleRepr a), IsPrimitive prim)
                    => ByteString
                    -> prim
                    -> a
                    -> gp (VertexStream prim (InputTupleRepr a))

    transform       :: (GPU a, GPU b
                       , Exp exp, exp ~ GP_Exp gp
                       , VertexOut vertexOut, vertexOut ~ GP_VertexOut gp)
                    => (exp V a -> vertexOut b)                       -- vertex shader
                    -> gp (VertexStream prim a)
                    -> gp (PrimitiveStream prim b)

    rasterize       :: ( GeometryShader geometryShader, geometryShader ~ GP_GeometryShader gp
                       , RasterContext rasterContext, rasterContext ~ GP_RasterContext gp)
                    => rasterContext primOut
                    -> geometryShader primIn primOut layerNum a b
                    -> gp (PrimitiveStream primIn a)
                    -> gp (FragmentStream layerNum b)

    frameBuffer     :: V2U                                          -- size: width, height
                    -> FrameBuffer layerCount t
                    -> gp (FrameBuffer layerCount (FTRepr' t))

    accumulate      :: (GPU a, GPU (FTRepr' b), IsValidOutput b
                       , Exp exp, exp ~ GP_Exp gp
                       , FragmentOut fragmentOut, fragmentOut ~ GP_FragmentOut gp
                       , FragmentFilter fragmentFilter, fragmentFilter ~ GP_FragmentFilter gp)    -- restriction: depth and stencil optional, arbitrary color component
                    => AccumulationContext b
                    -> fragmentFilter a
                    -> (exp F a -> fragmentOut (NoStencilRepr b))     -- fragment shader
                    -> gp (FragmentStream layerCount a)
                    -> gp (FrameBuffer layerCount (FTRepr' b))
                    -> gp (FrameBuffer layerCount (FTRepr' b))

    prjFrameBuffer  :: ( TupleIdx tupleIdx
                       , Image image)
                    => ByteString                       -- internal image output (can be allocated on request)
                    -> tupleIdx (EltRepr b) t
                    -> gp (FrameBuffer layerCount b)
                    -> gp (image layerCount t)

    prjImage        :: (LesserEq idx layerCount, Image image)
                    => ByteString                       -- internal image output (can be allocated on request)
                    -> idx
                    -> gp (image layerCount t)
                    -> gp (image N1 t)