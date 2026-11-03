import UIKit

final class Thumbnails {
    static let shared = Thumbnails()

    private let images = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "com.vaditim.notes.thumbnails", qos: .utility)

    private init() {
        images.totalCostLimit = Tokens.shared.memory.thumbnailCacheMegabytes * 1024 * 1024
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.removeAll()
        }
    }

    func image(for key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    func render(key: String, draw: @escaping () -> UIImage, completion: @escaping (UIImage) -> Void) {
        perform(draw) { [weak self] image in
            self?.images.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            completion(image)
        }
    }

    func perform<Result>(_ work: @escaping () -> Result, completion: @escaping (Result) -> Void) {
        queue.async {
            let result = work()
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func removeAll() {
        images.removeAllObjects()
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}
