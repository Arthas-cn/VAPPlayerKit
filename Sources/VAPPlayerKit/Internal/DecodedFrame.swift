import CoreVideo
import CoreMedia

struct DecodedFrame {
    let token: SessionToken
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let duration: CMTime
}
